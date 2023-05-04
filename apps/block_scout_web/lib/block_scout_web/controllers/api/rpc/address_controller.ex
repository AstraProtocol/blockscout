defmodule BlockScoutWeb.API.RPC.AddressController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.AddressController, only: [async_address_counters: 1]
  import BlockScoutWeb.Chain, only: [get_next_page_number: 1, next_page_path: 1]

  alias BlockScoutWeb.API.RPC.Helpers
  alias Explorer.{Chain, Market, Etherscan, PagingOptions}
  alias Explorer.Chain.{Address, Wei}
  alias Explorer.Etherscan.{Addresses, Blocks}
  alias Indexer.Fetcher.CoinBalanceOnDemand

  def listaccounts(conn, params) do
    options =
      params
      |> optional_params()
      |> Map.put_new(:page_number, 0)
      |> Map.put_new(:page_size, 10)

    accounts = list_accounts(options)

    conn
    |> put_status(200)
    |> render(:listaccounts, %{accounts: accounts})
  end

  def getaddress(conn, params) do
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param) do
      case Chain.hash_to_address(address_hash) do
        {:ok, address} ->
          render(conn, "getaddress.json",
            %{address_detail: address, verified: Chain.smart_contract_fully_verified?(address_param)}
          )
        _ ->
          case Chain.Hash.Address.validate(address_param) do
            {:ok, _} ->
              address = %Chain.Address{
                hash: address_hash,
                smart_contract: nil,
                token: nil,
                fetched_coin_balance: %Wei{value: Decimal.new(0)}
              }
              Chain.create_address(%{hash: to_string(address_hash)})
              render(conn, "getaddress.json",
                %{address_detail: address, verified: false}
              )
            _ ->
              render(conn, :error, error: "Address not found")
          end
      end
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")
    end
  end

  def eth_get_balance(conn, params) do
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:block_param, {:ok, block}} <- {:block_param, fetch_block_param(params)},
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:balance, {:ok, balance}} <- {:balance, Blocks.get_balance_as_of_block(address_hash, block)} do
      render(conn, :eth_get_balance, %{balance: Wei.hex_format(balance)})
    else
      {:address_param, :error} ->
        conn
        |> put_status(400)
        |> render(:eth_get_balance_error, %{message: "Query parameter 'address' is required"})

      {:format, :error} ->
        conn
        |> put_status(400)
        |> render(:eth_get_balance_error, %{error: "Invalid address hash"})

      {:block_param, :error} ->
        conn
        |> put_status(400)
        |> render(:eth_get_balance_error, %{error: "Invalid block"})

      {:balance, {:error, :not_found}} ->
        conn
        |> put_status(404)
        |> render(:eth_get_balance_error, %{error: "Balance not found"})
    end
  end

  def balance(conn, params, template \\ :balance) do
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hashes}} <- to_address_hashes(address_param) do
      addresses = hashes_to_addresses(address_hashes)
      render(conn, template, %{addresses: addresses})
    else
      {:address_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid address hash")
    end
  end

  def update_balance(conn, params) do
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:block_param, {:ok, block_param}} <- fetch_block(params),
         {:balance_param, {:ok, balance_param}} <- fetch_balance(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:ok, address} <- Chain.hash_to_address(address_hash) do

      block_number_param = String.to_integer(block_param)
      if block_number_param - (address.fetched_coin_balance_block_number || 0) >= 10 do
        change_param = %{
          fetched_coin_balance: String.to_integer(balance_param),
          fetched_coin_balance_block_number: block_number_param,
          hash: address_param
        }
        params = []
        params = [change_param | params]

        Chain.import(%{
          addresses: %{params: params, with: :balance_changeset},
          broadcast: :on_demand
        })
      end

      send_resp(conn,
                :ok,
                %{
                  "message" => "OK",
                  "result" => %{
                    "address" => address_param,
                    "balance" => balance_param
                  },
                  "status" => "1"
                } |> Jason.encode!()
              )
    else
      {:address_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'address' is required")

      {:block_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'block' is required")

      {:balance_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'balance' is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid address hash")

      {:error, :not_found}  ->
        conn
        |> put_status(200)
        |> render(:error, error: "Address not found")
    end
  end

  def balancemulti(conn, params) do
    balance(conn, params, :balancemulti)
  end

  def pendingtxlist(conn, params) do
    options = optional_params(params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:ok, transactions} <- list_pending_transactions(address_hash, options) do
      render(conn, :pendingtxlist, %{transactions: transactions})
    else
      {:address_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid address format")

      {:error, :not_found} ->
        render(conn, :error, error: "No transactions found", data: [])
    end
  end

  def txlist(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            :block => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional
          }
        ]
        |> Keyword.merge(current_filter(params))
        |> Keyword.merge(paging_options_token_transfer_list(params, options))

      transactions_plus_one = Chain.address_to_transactions_with_rewards(address_hash, full_options)
      {transactions, next_page} = split_list_by_page(transactions_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_transaction = Enum.at(transactions, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_transaction.block_number,
          "index" => last_transaction.index
        }
        render(conn, "txlist.json", %{
          transactions: transactions,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "txlist.json", %{
          transactions: transactions,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:address_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid address format")

      {:address, :not_found} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Address not found")
    end
  end

  def txlistdeposit(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            :block => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional
          }
        ]
        |> Keyword.merge(paging_options_token_transfer_list(params, options))

      transactions_plus_one = Chain.address_to_deposit_transactions(address_hash, full_options)
      {transactions, next_page} = split_list_by_page(transactions_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_transaction = Enum.at(transactions, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_transaction.block_number,
          "index" => last_transaction.index
        }
        render(conn, "txlist.json", %{
          transactions: transactions,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "txlist.json", %{
          transactions: transactions,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:address_param, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Invalid address format")

      {:address, :not_found} ->
        conn
        |> put_status(200)
        |> render(:error, error: "Address not found")
    end
  end

  def txlistinternal(conn, params) do
    case {Map.fetch(params, "txhash"), Map.fetch(params, "address")} do
      {:error, :error} ->
        render(conn, :error, error: "Query parameter txhash or address is required")

      {{:ok, txhash_param}, :error} ->
        txlistinternal(conn, params, txhash_param, :txhash)

      {:error, {:ok, address_param}} ->
        txlistinternal(conn, params, address_param, :address)
    end
  end

  def txlistinternal(conn, params, txhash_param, :txhash) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:format, {:ok, transaction_hash}} <- to_transaction_hash(txhash_param),
         :ok <- Chain.check_transaction_exists(transaction_hash) do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 50)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            [transaction: :block] => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional
          }
        ] |> Keyword.merge(paging_options_list_internal_transactions(params, options))

      internal_transactions_plus_one = Chain.transaction_to_internal_transactions(transaction_hash, full_options)
      {internal_transactions, next_page} =
        split_list_by_page(internal_transactions_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_internal_transaction = Enum.at(internal_transactions, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_internal_transaction.block_number,
          "transaction_index" => last_internal_transaction.transaction_index,
          "index" => last_internal_transaction.index
        }

        render(conn, "txlistinternalpagination.json", %{
          internal_transactions: internal_transactions,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "txlistinternalpagination.json", %{
          internal_transactions: internal_transactions,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:format, :error} ->
        render(conn, :error, error: "Invalid txhash format")

      :error ->
        render(conn, :error, error: "No internal transactions found", data: [])
    end
  end

  def txlistinternal(conn, params, address_param, :address) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional
          }
        ] |> Keyword.merge(paging_options_list_internal_transactions(params, options))

      internal_transactions_plus_one = Chain.address_to_internal_transactions(address_hash, full_options)
      {internal_transactions, next_page} =
        split_list_by_page(internal_transactions_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_internal_transaction = Enum.at(internal_transactions, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_internal_transaction.block_number,
          "transaction_index" => last_internal_transaction.transaction_index,
          "index" => last_internal_transaction.index
        }

        render(conn, "txlistinternalpagination.json", %{
          internal_transactions: internal_transactions,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "txlistinternalpagination.json", %{
          internal_transactions: internal_transactions,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {_, :not_found} ->
        render(conn, :error, error: "Address not found", data: [])
    end
  end

  def getlisttokentransfers(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional,
            [token_transfers: :token] => :optional,
            [token_transfers: :to_address] => :optional,
            [token_transfers: :from_address] => :optional,
            [token_transfers: :token_contract_address] => :optional,
            :block => :required
          }
        ] |> Keyword.merge(paging_options_token_transfer_list(params, options))

      transactions_plus_one =
        Chain.address_hash_to_token_transfers(
          address_hash,
          full_options
        )

      {transactions, next_page} = split_list_by_page(transactions_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_transaction = Enum.at(transactions, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_transaction.block_number,
          "index" => last_transaction.index
        }

        render(conn, "getlisttokentransfers.json", %{
          token_transfers: transactions,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getlisttokentransfers.json", %{
          token_transfers: transactions,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {_, :not_found} ->
        render(conn, :error, error: "Address not found")
    end
  end

  def getlogs(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param) do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      logs_plus_one = Chain.address_to_logs(address_hash, paging_options_list_internal_transactions(params, options))

      {logs, next_page} = split_list_by_page(logs_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        last_log = Enum.at(logs, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => last_log.transaction.block_number,
          "transaction_index" => last_log.transaction.index,
          "index" => last_log.index
        }

        render(conn, "getlogs.json", %{
          logs: logs,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getlogs.json", %{
          logs: logs,
          has_next_page: false,
          next_page_path: ""}
        )
      end

    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")
    end
  end

  def tokentx(conn, params) do
    options = optional_params(params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:contract_address, {:ok, contract_address_hash}} <- to_contract_address_hash(params["contractaddress"]),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)},
         {:ok, token_transfers} <- list_token_transfers(address_hash, contract_address_hash, options) do
      render(conn, :tokentx, %{token_transfers: token_transfers})
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {:contract_address, :error} ->
        render(conn, :error, error: "Invalid contract address format")

      {_, :not_found} ->
        render(conn, :error, error: "No token transfers found", data: [])
    end
  end

  @tokenbalance_required_params ~w(contractaddress address)

  def tokenbalance(conn, params) do
    with {:required_params, {:ok, fetched_params}} <- fetch_required_params(params, @tokenbalance_required_params),
         {:format, {:ok, validated_params}} <- to_valid_format(fetched_params, :tokenbalance) do
      token_balance = get_token_balance(validated_params)
      render(conn, "tokenbalance.json", %{token_balance: token_balance})
    else
      {:required_params, {:error, missing_params}} ->
        error = "Required query parameters missing: #{Enum.join(missing_params, ", ")}"
        render(conn, :error, error: error)

      {:format, {:error, param}} ->
        render(conn, :error, error: "Invalid #{param} format")
    end
  end

  def tokenlist(conn, params) do
    pagination_options = Helpers.put_pagination_api_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      token_balances_plus_one =
        address_hash
        |> Chain.fetch_last_token_balances_filter_type(paging_options_token_list(params, options), params["type"])
        |> Market.add_price()

      {token_balances, next_page} = split_list_by_page(token_balances_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        {%Address.CurrentTokenBalance{value: value, token: token}, _} = Enum.at(token_balances, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "limit" => options_with_defaults.page_size,
          "token_name" => token.name,
          "token_type" => token.type,
          "value" => to_string(value)
        }
        render(conn, :token_list, %{
          token_list: token_balances,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, :token_list, %{
          token_list: token_balances,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {_, :not_found} ->
        render(conn, :error, error: "No tokens found", data: [])
    end
  end

  def getminedblocks(conn, params) do
    options = Helpers.put_pagination_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)},
         {:ok, blocks} <- list_blocks(address_hash, options) do
      render(conn, :getminedblocks, %{blocks: blocks})
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {_, :not_found} ->
        render(conn, :error, error: "No blocks found", data: [])
    end
  end

  def gettopaddressesbalance(conn, params) do
    with pagination_options <- Helpers.put_pagination_options(%{}, params) do
      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      addresses_plus_one =
        params
        |> paging_options_top_addresses_balance(options)
        |> Chain.list_top_addresses()

      {addresses, next_page} = split_list_by_page(addresses_plus_one, options_with_defaults.page_size)

      items = for {address, tx_count} <- addresses do
        %{
          address: address,
          tx_count: tx_count
        }
      end

      if length(next_page) > 0 do
        {%Address{hash: hash, fetched_coin_balance: fetched_coin_balance}, _} = Enum.at(addresses, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "hash" => hash,
          "fetched_coin_balance" => Decimal.to_string(fetched_coin_balance.value)
        }
        render(conn, "gettopaddressesbalance.json", %{
          top_addresses_balance: items,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "gettopaddressesbalance.json", %{
          top_addresses_balance: items,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    end
  end

  def getcoinbalancehistory(conn, params) do
    pagination_options = Helpers.put_pagination_options(%{}, params)

    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)} do

      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = %PagingOptions{
        key: nil,
        page_number: options_with_defaults.page_number,
        page_size: options_with_defaults.page_size + 1
      }

      full_options = paging_options_coin_balance_history(params, options)

      coin_balances_plus_one = Chain.address_to_coin_balances(address_hash, full_options)

      {coin_balances, next_page} = split_list_by_page(coin_balances_plus_one, options_with_defaults.page_size)

      if length(next_page) > 0 do
        coin_balance = Enum.at(coin_balances, -1)
        next_page_params = %{
          "page" => get_next_page_number(options_with_defaults.page_number),
          "offset" => options_with_defaults.page_size,
          "block_number" => coin_balance.block_number
        }
        render(conn, "getcoinbalancehistory.json", %{
          coin_balances: coin_balances,
          has_next_page: true,
          next_page_path: next_page_path(next_page_params)}
        )
      else
        render(conn, "getcoinbalancehistory.json", %{
          coin_balances: coin_balances,
          has_next_page: false,
          next_page_path: ""}
        )
      end
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")
    end
  end

  def getaddresscounters(conn, params) do
    with {:address_param, {:ok, address_param}} <- fetch_address(params),
         {:format, {:ok, address_hash}} <- to_address_hash(address_param),
         {:address, :ok} <- {:address, Chain.check_address_exists(address_hash)},
         {:ok, address} <- Chain.hash_to_address(address_hash) do

      {validation_count} = async_address_counters(address)
      transactions_from_db = address.transactions_count || 0
      token_transfers_from_db = address.token_transfers_count || 0
      address_gas_usage_from_db = address.gas_used || 0

      render(conn, "getaddresscounters.json", %{
        transaction_count: transactions_from_db,
        token_transfer_count: token_transfers_from_db,
        gas_usage_count: address_gas_usage_from_db,
        validation_count: validation_count,
        address: address
      })
    else
      {:address_param, :error} ->
        render(conn, :error, error: "Query parameter 'address' is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid address format")

      {:address, :not_found} ->
        render(conn, :error, error: "Address not found")

      _ ->
        render(conn, "getaddresscounters.json", %{
          transaction_count: 0,
          token_transfer_count: 0,
          gas_usage_count: 0,
          validation_count: 0
        })
    end
 end

  @doc """
  Sanitizes optional params.

  """
  @spec optional_params(map()) :: map()
  def optional_params(params) do
    %{}
    |> put_order_by_direction(params)
    |> Helpers.put_pagination_options(params)
    |> put_block(params, "start_block")
    |> put_block(params, "end_block")
    |> put_filter_by(params)
    |> put_timestamp(params, "start_timestamp")
    |> put_timestamp(params, "end_timestamp")
  end

  @doc """
  Fetches required params. Returns error tuple if required params are missing.

  """
  @spec fetch_required_params(map(), list()) :: {:required_params, {:ok, map()} | {:error, [String.t(), ...]}}
  def fetch_required_params(params, required_params) do
    fetched_params = Map.take(params, required_params)

    result =
      if all_of_required_keys_found?(fetched_params, required_params) do
        {:ok, fetched_params}
      else
        missing_params = get_missing_required_params(fetched_params, required_params)
        {:error, missing_params}
      end

    {:required_params, result}
  end

  defp paging_options_top_addresses_balance(params, paging_options) do
    if !is_nil(params["fetched_coin_balance"]) and !is_nil(params["hash"]) do
      {coin_balance, ""} = Integer.parse(params["fetched_coin_balance"])
      {:ok, address_hash} = Chain.string_to_address_hash(params["hash"])
      [paging_options: %{paging_options | key: {%Wei{value: Decimal.new(coin_balance)}, address_hash}}]
    else
      [paging_options: paging_options]
    end
  end

  defp paging_options_coin_balance_history(params, paging_options) do
    if !is_nil(params["block_number"]) do
      case Integer.parse(params["block_number"]) do
        {block_number, ""} ->
          [paging_options: %{paging_options | key: {block_number}}]
        _ ->
          [paging_options: paging_options]
      end
    else
      [paging_options: paging_options]
    end
  end

  defp paging_options_list_internal_transactions(params, paging_options) do
    if !is_nil(params["block_number"]) and !is_nil(params["transaction_index"]) and !is_nil(params["index"]) do
      {block_number, ""} = Integer.parse(params["block_number"])
      {transaction_index, ""} = Integer.parse(params["transaction_index"])
      {index, ""} = Integer.parse(params["index"])

      [paging_options: %{paging_options | key: {block_number, transaction_index, index}}]
    else
      [paging_options: paging_options]
    end
  end

  defp paging_options_token_list(params, paging_options) do
    if !is_nil(params["token_name"]) and !is_nil(params["token_type"]) and !is_nil(params["value"]) do
      [paging_options: %{paging_options | key: {params["token_name"], params["token_type"], params["value"]}}]
    else
      [paging_options: paging_options]
    end
  end

  defp paging_options_token_transfer_list(params, paging_options) do
    if !is_nil(params["block_number"]) and !is_nil(params["index"]) do
      [paging_options: %{paging_options | key: {params["block_number"], params["index"]}}]
    else
      [paging_options: paging_options]
    end
  end

  defp split_list_by_page(list_plus_one, page_size), do: Enum.split(list_plus_one, page_size)

  defp fetch_block_param(%{"block" => "latest"}), do: {:ok, :latest}
  defp fetch_block_param(%{"block" => "earliest"}), do: {:ok, :earliest}
  defp fetch_block_param(%{"block" => "pending"}), do: {:ok, :pending}

  defp fetch_block_param(%{"block" => string_integer}) when is_bitstring(string_integer) do
    case Integer.parse(string_integer) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp fetch_block_param(%{"block" => _block}), do: :error
  defp fetch_block_param(_), do: {:ok, :latest}

  defp to_valid_format(params, :tokenbalance) do
    result =
      with {:ok, contract_address_hash} <- to_address_hash(params, "contractaddress"),
           {:ok, address_hash} <- to_address_hash(params, "address") do
        {:ok, %{contract_address_hash: contract_address_hash, address_hash: address_hash}}
      else
        {:error, _param_key} = error -> error
      end

    {:format, result}
  end

  defp all_of_required_keys_found?(fetched_params, required_params) do
    Enum.all?(required_params, &Map.has_key?(fetched_params, &1))
  end

  defp get_missing_required_params(fetched_params, required_params) do
    fetched_keys = fetched_params |> Map.keys() |> MapSet.new()

    required_params
    |> MapSet.new()
    |> MapSet.difference(fetched_keys)
    |> MapSet.to_list()
  end

  defp fetch_address(params) do
    {:address_param, Map.fetch(params, "address")}
  end

  defp fetch_block(params) do
    {:block_param, Map.fetch(params, "block")}
  end

  defp fetch_balance(params) do
    {:balance_param, Map.fetch(params, "balance")}
  end

  defp to_address_hashes(address_param) when is_binary(address_param) do
    address_param
    |> String.split(",")
    |> Enum.take(20)
    |> to_address_hashes()
  end

  defp to_address_hashes(address_param) when is_list(address_param) do
    address_hashes = address_param_to_address_hashes(address_param)

    if any_errors?(address_hashes) do
      {:format, :error}
    else
      {:format, {:ok, address_hashes}}
    end
  end

  defp address_param_to_address_hashes(address_param) do
    Enum.map(address_param, fn single_address ->
      case Chain.string_to_address_hash(single_address) do
        {:ok, address_hash} -> address_hash
        :error -> :error
      end
    end)
  end

  defp any_errors?(address_hashes) do
    Enum.any?(address_hashes, &(&1 == :error))
  end

  defp list_accounts(%{page_number: page_number, page_size: page_size}) do
    offset = (max(page_number, 1) - 1) * page_size

    # limit is just page_size
    offset
    |> Addresses.list_ordered_addresses(page_size)
    |> trigger_balances_and_add_status()
  end

  defp hashes_to_addresses(address_hashes) do
    address_hashes
    |> Chain.hashes_to_addresses()
    |> trigger_balances_and_add_status()
    |> add_not_found_addresses(address_hashes)
  end

  defp add_not_found_addresses(addresses, hashes) do
    found_hashes = MapSet.new(addresses, & &1.hash)

    hashes
    |> MapSet.new()
    |> MapSet.difference(found_hashes)
    |> hashes_to_addresses(:not_found)
    |> Enum.concat(addresses)
  end

  defp hashes_to_addresses(hashes, :not_found) do
    Enum.map(hashes, fn hash ->
      %Address{
        hash: hash,
        fetched_coin_balance: %Wei{value: 0}
      }
    end)
  end

  defp trigger_balances_and_add_status(addresses) do
    Enum.map(addresses, fn address ->
      case CoinBalanceOnDemand.trigger_fetch(address) do
        :current ->
          %{address | stale?: false}

        _ ->
          %{address | stale?: true}
      end
    end)
  end

  defp to_contract_address_hash(nil), do: {:contract_address, {:ok, nil}}

  defp to_contract_address_hash(address_hash_string) do
    {:contract_address, Chain.string_to_address_hash(address_hash_string)}
  end

  defp to_address_hash(address_hash_string) do
    {:format, Chain.string_to_address_hash(address_hash_string)}
  end

  defp to_address_hash(params, param_key) do
    case Chain.string_to_address_hash(params[param_key]) do
      {:ok, address_hash} -> {:ok, address_hash}
      :error -> {:error, param_key}
    end
  end

  defp to_transaction_hash(transaction_hash_string) do
    {:format, Chain.string_to_transaction_hash(transaction_hash_string)}
  end

  defp put_order_by_direction(options, params) do
    case params do
      %{"sort" => sort} when sort in ["asc", "desc"] ->
        order_by_direction = String.to_existing_atom(sort)
        Map.put(options, :order_by_direction, order_by_direction)

      _ ->
        options
    end
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp put_block(options, params, key) do
    with %{^key => block_param} <- params,
         {block_number, ""} <- Integer.parse(block_param) do
      Map.put(options, String.to_atom(key), block_number)
    else
      _ ->
        options
    end
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp put_filter_by(options, params) do
    case params do
      %{"filter_by" => filter_by} when filter_by in ["from", "to"] ->
        Map.put(options, String.to_atom("filter_by"), filter_by)

      _ ->
        options
    end
  end

  def put_timestamp({:ok, options}, params, timestamp_param_key) do
    options = put_timestamp(options, params, timestamp_param_key)
    {:ok, options}
  end

  # sobelow_skip ["DOS.StringToAtom"]
  def put_timestamp(options, params, timestamp_param_key) do
    with %{^timestamp_param_key => timestamp_param} <- params,
         {unix_timestamp, ""} <- Integer.parse(timestamp_param),
         {:ok, timestamp} <- DateTime.from_unix(unix_timestamp) do
      Map.put(options, String.to_atom(timestamp_param_key), timestamp)
    else
      _ ->
        options
    end
  end

  defp list_pending_transactions(address_hash, options) do
    case Etherscan.list_pending_transactions(address_hash, options) do
      [] -> {:error, :not_found}
      pending_transactions -> {:ok, pending_transactions}
    end
  end

  defp list_token_transfers(address_hash, contract_address_hash, options) do
    case Etherscan.list_token_transfers(address_hash, contract_address_hash, options) do
      [] -> {:error, :not_found}
      token_transfers -> {:ok, token_transfers}
    end
  end

  defp list_blocks(address_hash, options) do
    case Etherscan.list_blocks(address_hash, options) do
      [] -> {:error, :not_found}
      blocks -> {:ok, blocks}
    end
  end

  defp get_token_balance(%{contract_address_hash: contract_address_hash, address_hash: address_hash}) do
    case Etherscan.get_token_balance(contract_address_hash, address_hash) do
      nil -> 0
      token_balance -> token_balance.value
    end
  end

  defp current_filter(params) do
    params
    |> Map.get("filter")
    |> case do
         "to" -> [direction: :to]
         "from" -> [direction: :from]
         _ -> []
       end
  end
end
