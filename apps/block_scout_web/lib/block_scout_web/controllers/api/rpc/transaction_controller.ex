defmodule BlockScoutWeb.API.RPC.TransactionController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain, only: [paging_options: 1, next_page_params: 3, split_list_by_page: 1]

  alias Explorer.Chain
  alias Explorer.Chain.Transaction

  def gettxinfo(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param),
         {:transaction, {:ok, %Transaction{revert_reason: revert_reason, error: error} = transaction}} <-
           transaction_from_hash(transaction_hash),
         paging_options <- paging_options(params) do
      from_api = true
      logs = Chain.transaction_to_logs(transaction_hash, from_api, paging_options)
      {logs, next_page} = split_list_by_page(logs)

      transaction_updated =
        if (error == "Reverted" || error == "execution reverted") && !revert_reason do
          %Transaction{transaction | revert_reason: Chain.fetch_tx_revert_reason(transaction)}
        else
          transaction
        end

      render(conn, :gettxinfo, %{
        transaction: transaction_updated,
        block_height: Chain.block_height(),
        logs: logs,
        next_page_params: next_page_params(next_page, logs, params)
      })
    else
      {:transaction, :error} ->
        render(conn, :error, error: "Transaction not found")

      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")
    end
  end

  def gettxcosmosinfo(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         true <- Chain.is_cosmos_tx(txhash_param),
         {:transaction, {:ok, %Transaction{revert_reason: revert_reason, error: error} = transaction}} <-
           transaction_from_cosmos_hash(txhash_param) do
      from_api = true
      logs = Chain.cosmos_hash_to_logs(txhash_param, from_api, necessity_by_association:
        %{
          [address: :names] => :optional
        }
      )

      transaction_updated =
        if (error == "Reverted" || error == "execution reverted") && !revert_reason do
          %Transaction{transaction | revert_reason: Chain.fetch_tx_revert_reason(transaction)}
        else
          transaction
        end

      render(conn, :gettxcosmosinfo, %{
        transaction: transaction_updated,
        block_height: Chain.block_height(),
        logs: logs}
      )
    else
      {:transaction, :error} ->
        render(conn, :error, error: "Transaction not found")

      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      false ->
        render(conn, :error, error: "Invalid txhash format")
    end
  end

  def getabibytxhash(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param),
         {:transaction, {:ok, transaction}} <- transaction_from_hash(transaction_hash) do
      with {:ok, contract} <- Chain.get_smart_contract_by_address_hash(transaction.to_address_hash) do
        render(conn, :getabibytxhash, %{
          abi: contract.abi}
        )
      else
        {:error, :not_found} ->
          case  Chain.get_contract_method_by_input_data(transaction.input) do
            nil ->
              render(conn, :getabibytxhash, %{
                abi: ""}
              )
            contract_method ->
              render(conn, :getabibytxhash, %{
                abi: contract_method.abi}
              )
          end
      end
    else
      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")

      {:transaction, :error} ->
        render(conn, :error, error: "Transaction not found")
    end
  end

  def gettxreceiptstatus(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param) do
      status = to_transaction_status(transaction_hash)
      render(conn, :gettxreceiptstatus, %{status: status})
    else
      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")
    end
  end

  def getstatus(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param) do
      error = to_transaction_error(transaction_hash)
      render(conn, :getstatus, %{error: error})
    else
      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")
    end
  end

  defp fetch_txhash(params) do
    {:txhash_param, Map.fetch(params, "txhash")}
  end

  defp transaction_from_hash(transaction_hash) do
    case Chain.hash_to_transaction(transaction_hash, necessity_by_association: %{block: :required}) do
      {:error, :not_found} -> {:transaction, :error}
      {:ok, transaction} -> {:transaction, {:ok, transaction}}
    end
  end

  defp transaction_from_cosmos_hash(cosmos_hash) do
    case Chain.cosmos_hash_to_transaction(cosmos_hash,
           necessity_by_association: %{
             [token_transfers: :token] => :optional,
             [token_transfers: :to_address] => :optional,
             [token_transfers: :from_address] => :optional,
             [token_transfers: :token_contract_address] => :optional,
             :block => :required
           }
         ) do
      {:error, :not_found} ->
        {:transaction, :error}
      {:ok, transaction} ->
        {:transaction, {:ok, Chain.preload_transaction_token_address_names(transaction)}}
    end
  end

  defp to_transaction_hash(transaction_hash_string) do
    {:format, Chain.string_to_transaction_hash(transaction_hash_string)}
  end

  defp to_transaction_status(transaction_hash) do
    case Chain.hash_to_transaction(transaction_hash) do
      {:error, :not_found} -> ""
      {:ok, transaction} -> transaction.status
    end
  end

  defp to_transaction_error(transaction_hash) do
    with {:ok, transaction} <- Chain.hash_to_transaction(transaction_hash),
         {:error, error} <- Chain.transaction_to_status(transaction) do
      error
    else
      _ -> ""
    end
  end
end
