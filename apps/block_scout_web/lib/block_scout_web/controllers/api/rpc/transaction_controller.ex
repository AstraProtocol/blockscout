defmodule BlockScoutWeb.API.RPC.TransactionController do
  use BlockScoutWeb, :controller

  alias Explorer.Chain
  alias Explorer.Chain.{Transaction, InternalTransaction}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Import.Runner.InternalTransactions

  def gettxinfo(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param),
         {:transaction, {:ok, %Transaction{revert_reason: revert_reason, error: error} = transaction}} <-
           transaction_from_hash(transaction_hash) do
      from_api = true
      logs = Chain.transaction_to_logs(transaction_hash, from_api, necessity_by_association:
        %{
          [address: :names] => :optional
        }
      )

      transaction_updated =
        if (error == "Reverted" || error == "execution reverted") && !revert_reason do
          %Transaction{transaction | revert_reason: Chain.transaction_to_revert_reason(transaction)}
        else
          transaction
        end

      render(conn, :gettxinfo, %{
        transaction: transaction_updated,
        block_height: Chain.block_height(),
        logs: logs}
      )
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
          %Transaction{transaction | revert_reason: Chain.transaction_to_revert_reason(transaction)}
        else
          transaction
        end

      render(conn, :gettxinfo, %{
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
      case transaction.input do
        %{bytes: ""} ->
          render(conn, :getabibytxhash, %{
            abi: "", verified: false}
          )
        _ ->
          contract_method = Chain.get_contract_method_by_input_data(transaction.input)
          case transaction.to_address && transaction.to_address.smart_contract do
            nil ->
              case contract_method do
                nil ->
                  render(conn, :getabibytxhash, %{
                    abi: "", verified: false}
                  )
                contract_method ->
                  render(conn, :getabibytxhash, %{
                    abi: contract_method.abi, verified: false}
                  )
              end
            smart_contract ->
              case contract_method do
                nil ->
                  full_abi = Chain.combine_proxy_implementation_abi(
                    smart_contract.address_hash,
                    smart_contract.abi
                  )
                  render(conn, :getabibytxhash, %{
                    abi: full_abi, verified: true}
                  )
                contract_method ->
                  render(conn, :getabibytxhash, %{
                    abi: contract_method.abi, verified: true}
                  )
              end
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

  def getrawtracebytxhash(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             transaction_hash,
             necessity_by_association: %{
               :block => :optional,
               [created_contract_address: :names] => :optional,
               [from_address: :names] => :optional,
               [to_address: :names] => :optional,
               [to_address: :smart_contract] => :optional,
               :token_transfers => :optional
             }
           ) do

      if is_nil(transaction.block_number) do
        render(conn, :getrawtracebytxhash, %{
          raw_trace: []}
        )
      else
        internal_transactions = Chain.all_transaction_to_internal_transactions(transaction_hash)
        first_trace_exists =
          Enum.find_index(internal_transactions, fn trace ->
            trace.index == 0
          end)

        json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

        internal_transactions =
         if first_trace_exists do
           internal_transactions
         else
          response =
            Chain.fetch_first_trace(
              [
                %{
                  block_hash: transaction.block_hash,
                  block_number: transaction.block_number,
                  hash_data: txhash_param,
                  transaction_index: transaction.index
                }
              ],
              json_rpc_named_arguments
            )

          case response do
            {:ok, first_trace_params} ->
              InternalTransactions.run_insert_only(first_trace_params, %{
                timeout: :infinity,
                timestamps: Import.timestamps(),
                internal_transactions: %{params: first_trace_params}
              })

              Chain.all_transaction_to_internal_transactions(transaction_hash)

            {:error, _} ->
              internal_transactions

            :ignore ->
              internal_transactions
          end
        end

        raw_trace = internal_transactions
                    |> InternalTransaction.internal_transactions_to_raw()

        render(conn, :getrawtracebytxhash, %{
          raw_trace: raw_trace}
        )
      end
    else
      {:txhash_param, :error} ->
        render(conn, :error, error: "Query parameter txhash is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")

      {:error, :not_found} ->
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

  def gettxswithtokentransfersbytxhashes(conn, params) do
    with {:txhash_param, {:ok, txhash_param}} <- fetch_txhash(params),
         {:format, {:ok, tx_hashes}} <- to_tx_hashes(txhash_param) do
      tx_list = Chain.hashes_to_transactions(tx_hashes,
        necessity_by_association: %{
        :block => :optional,
        [created_contract_address: :names] => :optional,
        [from_address: :names] => :optional,
        [to_address: :names] => :optional
      })
      render(conn, "txlist.json", %{transactions: tx_list})
    else
      {:txhash_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter txhash is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid txhash format")
    end
  end

  defp to_tx_hashes(txhash_param) when is_binary(txhash_param) do
    txhash_param
    |> String.split(",")
    |> Enum.take(20)
    |> to_tx_hashes()
  end

  defp to_tx_hashes(txhash_param) when is_list(txhash_param) do
    tx_hashes = tx_param_to_tx_hashes(txhash_param)

    if any_errors?(tx_hashes) do
      {:format, :error}
    else
      {:format, {:ok, tx_hashes}}
    end
  end

  defp tx_param_to_tx_hashes(txhash_param) do
    Enum.map(txhash_param, fn single_txhash ->
      case Chain.string_to_transaction_hash(single_txhash) do
        {:ok, tx_hash} -> tx_hash
        :error -> :error
      end
    end)
  end

  defp any_errors?(tx_hashes) do
    Enum.any?(tx_hashes, &(&1 == :error))
  end

  defp fetch_txhash(params) do
    {:txhash_param, Map.fetch(params, "txhash")}
  end

  defp transaction_from_hash(transaction_hash) do
    case Chain.hash_to_transaction(transaction_hash,
           necessity_by_association: %{
             [token_transfers: :token] => :optional,
             [token_transfers: :to_address] => :optional,
             [token_transfers: :from_address] => :optional,
             [token_transfers: :token_contract_address] => :optional,
             [to_address: :smart_contract] => :optional,
             [to_address: :names] => :optional,
             [to_address: :contracts_creation_internal_transaction] => :optional,
             [to_address: :token] => :optional,
             [to_address: :contracts_creation_transaction] => :optional,
             [from_address: :names] => :optional,
             [created_contract_address: :names] => :optional,
             block: :required
           }
         ) do
      {:error, :not_found} ->
        {:transaction, :error}
      {:ok, transaction} ->
        {:transaction, {:ok, Chain.preload_transaction_token_address_names(transaction)}}
    end
  end

  defp transaction_from_cosmos_hash(cosmos_hash) do
    case Chain.cosmos_hash_to_transaction(cosmos_hash,
           necessity_by_association: %{
             [token_transfers: :token] => :optional,
             [token_transfers: :to_address] => :optional,
             [token_transfers: :from_address] => :optional,
             [token_transfers: :token_contract_address] => :optional,
             [to_address: :smart_contract] => :optional,
             [to_address: :names] => :optional,
             [to_address: :contracts_creation_internal_transaction] => :optional,
             [to_address: :token] => :optional,
             [to_address: :contracts_creation_transaction] => :optional,
             [from_address: :names] => :optional,
             [created_contract_address: :names] => :optional,
             block: :required
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
