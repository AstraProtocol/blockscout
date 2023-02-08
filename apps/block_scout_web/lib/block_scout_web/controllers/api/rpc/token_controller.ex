defmodule BlockScoutWeb.API.RPC.TokenController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.API.RPC.Helpers
  alias Explorer.{Chain, PagingOptions}
  alias Explorer.Counters.{TokenHoldersCounter, TokenTransfersCounter}

  import BlockScoutWeb.Chain, only: [get_next_page_number: 1, next_page_path: 1]

  def gettoken(conn, params) do
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param),
         {:token, {:ok, token}} <- {:token, Chain.token_from_address_hash(address_hash)} do
      {transfers_count, holders_count} = fetch_token_counters(address_hash, 30_000)
      token_detail = %{
        token: token,
        transfers_count: transfers_count,
        holders_count: holders_count
      }
      render(conn, "gettoken.json", %{token_detail: token_detail})
    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")

      {:token, {:error, :not_found}} ->
        render(conn, :error, error: "contract address not found")
    end
  end

  def getmetadata(conn, params) do
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:tokenid_param, {:ok, tokenid_param}} <- fetch_tokenid(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param),
         :ok <- Chain.check_erc721_token_instance_exists(tokenid_param, address_hash) do
      case Chain.erc721_token_instance_from_token_id_and_token_address(
             tokenid_param,
             address_hash
           )
        do
        {:ok, token_instance} ->
          render(conn, "getmetadata.json", %{token_instance: token_instance})
        _ ->
          render(conn, :error, error: "Token instance not found")
      end
    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:tokenid_param, :error} ->
        render(conn, :error, error: "Query parameter token id is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")

      :not_found ->
        render(conn, :error, error: "Token instance not found")
    end
  end

  def getinventory(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param),
         {:ok, token} <- Chain.token_from_address_hash(address_hash) do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      unique_tokens_plus_one = Chain.address_to_unique_tokens(
        token.contract_address_hash,
        paging_options_unique_tokens(params, options)
      )

      {unique_tokens, next_page} = split_list_by_page(unique_tokens_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_unique_tokens = Enum.at(unique_tokens, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "token_id" => last_unique_tokens.token_id
        }

        render(conn, "getinventory.json", %{
          unique_tokens: unique_tokens,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getinventory.json", %{
          unique_tokens: unique_tokens,
          has_next_page: false,
          next_page_path: ""}
        )
      end

    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")

      {:error, :not_found} ->
        render(conn, :error, error: "Cannot found token from contract address hash")
    end
  end

  def tokentransfersbytokenid(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:tokenid_param, {:ok, tokenid_param}} <- fetch_tokenid(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param),
         {:ok, _} <- to_token_from_address_hash(address_hash) do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      token_transfers_plus_one =
        Chain.fetch_token_transfers_from_token_hash_and_token_id(
          address_hash,
          tokenid_param,
          paging_options_token_transfer_list(params, options)
        )

      {token_transfers, next_page} = split_list_by_page(token_transfers_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_token_transfer = Enum.at(token_transfers, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_token_transfer.block_number,
          "index" => last_token_transfer.transaction.index
        }

        render(conn, "getlisttokentransfers.json", %{
          token_transfers: token_transfers,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getlisttokentransfers.json", %{
          token_transfers: token_transfers,
          has_next_page: false,
          next_page_path: ""}
        )
      end

    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:tokenid_param, :error} ->
        render(conn, :error, error: "Query parameter token id is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")

      {:error, :not_found}  ->
        render(conn, :error, error: "Token not found in contract address")
    end
  end

  def getlisttokentransfers(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param) do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      token_transfers_plus_one =
        Chain.fetch_token_transfers_from_token_hash(address_hash, paging_options_token_transfer_list(params, options))

      {token_transfers, next_page} = split_list_by_page(token_transfers_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_token_transfer = Enum.at(token_transfers, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_token_transfer.block_number,
          "index" => last_token_transfer.transaction.index
        }

        render(conn, "getlisttokentransfers.json", %{
          token_transfers: token_transfers,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getlisttokentransfers.json", %{
          token_transfers: token_transfers,
          has_next_page: false,
          next_page_path: ""}
        )
      end

    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")
    end
  end

  def gettokenholders(conn, params) do
    with pagination_options <- Helpers.put_pagination_options(%{}, params),
         {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param) do
      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = [
        paging_options: %PagingOptions{
          key: nil,
          page_number: options_with_defaults.page_number,
          page_size: options_with_defaults.page_size
        }
      ]

      has_next_option = [
        paging_options: %PagingOptions{
          key: nil,
          page_number: options_with_defaults.page_number * options_with_defaults.page_size + 1,
          page_size: 1
        }
      ]

      from_api = true
      token_holders = Chain.fetch_token_holders_from_token_hash(address_hash, from_api, options)
      next_token_holders = Chain.fetch_token_holders_from_token_hash(address_hash, from_api, has_next_option)
      if length(next_token_holders) > 0 do
        render(conn, "gettokenholders.json", %{token_holders: token_holders, hasNextPage: true})
      else
        render(conn, "gettokenholders.json", %{token_holders: token_holders, hasNextPage: false})
      end
    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")
    end
  end

  def getlisttokens(conn, params) do
    with pagination_options <- Helpers.put_pagination_options(%{}, params) do
      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = [
        paging_options: %PagingOptions{
          key: nil,
          page_number: options_with_defaults.page_number,
          page_size: options_with_defaults.page_size
        }
      ]

      has_next_option = [
        paging_options: %PagingOptions{
          key: nil,
          page_number: options_with_defaults.page_number * options_with_defaults.page_size + 1,
          page_size: 1
        }
      ]

      tokens = Chain.list_top_tokens(nil, options)
      next_tokens = Chain.list_top_tokens(nil, has_next_option)

      if length(next_tokens) > 0 do
        render(conn, "getlisttokens.json", %{list_tokens: tokens, hasNextPage: true})
      else
        render(conn, "getlisttokens.json", %{list_tokens: tokens, hasNextPage: false})
      end
    end
  end

  defp paging_options_token_transfer_list(params, paging_options) do
    if !is_nil(params["block_number"]) and !is_nil(params["index"]) do
      [paging_options: %{paging_options | key: {params["block_number"], params["index"]}}]
    else
      [paging_options: paging_options]
    end
  end

  defp paging_options_unique_tokens(params, paging_options) do
    if !is_nil(params["token_id"]) do
      [paging_options: %{paging_options | key: {params["token_id"]}}]
    else
      [paging_options: paging_options]
    end
  end

  defp split_list_by_page(list_plus_one, page_size), do: Enum.split(list_plus_one, page_size)

  defp fetch_contractaddress(params) do
    {:contractaddress_param, Map.fetch(params, "contractaddress")}
  end

  defp fetch_tokenid(params) do
    {:tokenid_param, Map.fetch(params, "tokenid")}
  end

  defp to_address_hash(address_hash_string) do
    {:format, Chain.string_to_address_hash(address_hash_string)}
  end

  defp to_token_from_address_hash(address_hash) do
      Chain.token_from_address_hash(address_hash)
  end

  defp fetch_token_counters(address_hash, timeout) do
    total_token_transfers_task =
      Task.async(fn ->
        TokenTransfersCounter.fetch(address_hash)
      end)

    total_token_holders_task =
      Task.async(fn ->
        TokenHoldersCounter.fetch(address_hash)
      end)

    [total_token_transfers_task, total_token_holders_task]
    |> Task.yield_many(timeout)
    |> Enum.map(fn {_task, res} ->
      case res do
        {:ok, result} ->
          result

        {:exit, _} ->
          0

        nil ->
          0
      end
    end)
    |> List.to_tuple()
  end
end
