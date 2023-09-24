defmodule Indexer.Fetcher.InternalTransaction do
  @moduledoc """
  Fetches and indexes `t:Explorer.Chain.InternalTransaction.t/0`.

  See `async_fetch/1` for details on configuring limits.
  """

  use Indexer.Fetcher
  use Spandex.Decorators

  require Logger
  import Indexer.Block.Fetcher, only: [async_import_coin_balances: 2]

  alias Explorer.Chain
  alias Explorer.Chain.Block
  alias Explorer.Chain.Cache.{Accounts, Blocks}
  alias Indexer.{BufferedTask, Tracer}
  alias Indexer.Fetcher.InternalTransaction.Supervisor, as: InternalTransactionSupervisor
  alias Indexer.Transform.Addresses

  @behaviour BufferedTask

  @max_batch_size 7
  @max_concurrency 3
  @defaults [
    flush_interval: :timer.seconds(3),
    max_concurrency: @max_concurrency,
    max_batch_size: @max_batch_size,
    poll: true,
    task_supervisor: Indexer.Fetcher.InternalTransaction.TaskSupervisor,
    metadata: [fetcher: :internal_transaction]
  ]

  @doc """
  Asynchronously fetches internal transactions.

  ## Limiting Upstream Load

  Internal transactions are an expensive upstream operation. The number of
  results to fetch is configured by `@max_batch_size` and represents the number
  of transaction hashes to request internal transactions in a single JSONRPC
  request. Defaults to `#{@max_batch_size}`.

  The `@max_concurrency` attribute configures the  number of concurrent requests
  of `@max_batch_size` to allow against the JSONRPC. Defaults to `#{@max_concurrency}`.

  *Note*: The internal transactions for individual transactions cannot be paginated,
  so the total number of internal transactions that could be produced is unknown.
  """
  @spec async_fetch([Block.block_number()]) :: :ok
  def async_fetch(block_numbers, timeout \\ 5000) when is_list(block_numbers) do
    if InternalTransactionSupervisor.disabled?() do
      :ok
    else
      BufferedTask.buffer(__MODULE__, block_numbers, timeout)
    end
  end

  @doc false
  def child_spec([init_options, gen_server_options]) do
    {state, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    unless state do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec " <>
              "to allow for json_rpc calls when running."
    end

    merged_init_opts =
      @defaults
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.put(:state, state)

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial, reducer, _json_rpc_named_arguments) do
    {:ok, final} =
      Chain.stream_blocks_with_unfetched_internal_transactions(initial, fn block_number, acc ->
        reducer.(block_number, acc)
      end)

    final
  end

  defp params(%{block_number: block_number, hash: hash, index: index,
                input: input, has_error_in_internal_txs: has_error_in_internal_txs}) when is_integer(block_number) do
    %{block_number: block_number, hash_data: to_string(hash), transaction_index: index,
      input: Explorer.Chain.Data.to_string(input), has_error_in_internal_txs: has_error_in_internal_txs}
  end

  @impl BufferedTask
  @decorate trace(
              name: "fetch",
              resource: "Indexer.Fetcher.InternalTransaction.run/2",
              service: :indexer,
              tracer: Tracer
            )
  def run(block_numbers, json_rpc_named_arguments) do
    unique_numbers = Enum.uniq(block_numbers)
    filtered_unique_numbers = EthereumJSONRPC.block_numbers_in_range(unique_numbers)

    filtered_unique_numbers_count = Enum.count(filtered_unique_numbers)
    Logger.metadata(count: filtered_unique_numbers_count)

    Logger.debug("fetching internal transactions for blocks")

    json_rpc_named_arguments
    |> Keyword.fetch!(:variant)
    |> case do
      EthereumJSONRPC.Nethermind ->
        EthereumJSONRPC.fetch_block_internal_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      EthereumJSONRPC.Erigon ->
        EthereumJSONRPC.fetch_block_internal_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      EthereumJSONRPC.Besu ->
        EthereumJSONRPC.fetch_block_internal_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      _ ->
        try do
          fetch_block_internal_transactions_by_transactions(filtered_unique_numbers, json_rpc_named_arguments)
        rescue
          error ->
            {:error, error}
        end
    end
    |> case do
      {:ok, internal_transactions_params} ->
        import_internal_transaction(internal_transactions_params, filtered_unique_numbers)

      {:error, reason} ->
        Logger.error(fn -> ["failed to fetch internal transactions for blocks: ", inspect(reason)] end,
          error_count: filtered_unique_numbers_count
        )
        #try do
        #  tx_hash = Enum.at(reason, 0)[:data][:transaction_hash]
        #  Chain.update_txs_has_error_in_internal_txs(tx_hash)
        #rescue
        #  _ ->
        #    :ok
        #end


        # re-queue the de-duped entries
        {:retry, filtered_unique_numbers}

      :ignore ->
        :ok
    end
  end

  def import_first_trace(internal_transactions_params) do
    imports =
      Chain.import(%{
        internal_transactions: %{params: internal_transactions_params, with: :blockless_changeset},
        timeout: :infinity
      })

    case imports do
      {:error, step, reason, _changes_so_far} ->
        Logger.error(
          fn ->
            [
              "failed to import first trace for tx: ",
              inspect(reason)
            ]
          end,
          step: step
        )
    end
  end

  defp blank_input?(str) do
    case str do
      nil -> true
      "0x" -> true
      "" -> true
      " " <> r -> blank_input?(r)
      _ -> false
    end
  end

  defp valid_param?(param) do
    cond do
      blank_input?(param[:input]) == true ->
        false
      #!is_nil(param[:has_error_in_internal_txs]) ->
      #  false
      true ->
        true
    end
  end

  defp fetch_block_internal_transactions_by_transactions(unique_numbers, json_rpc_named_arguments) do
    Enum.reduce(unique_numbers, {:ok, []}, fn
      block_number, {:ok, acc_list} ->
        transactions = block_number
                       |> Chain.get_transactions_of_block_number()
                       |> Enum.map(&params(&1))
                       |> Enum.filter(fn param -> valid_param?(param) end)
                       |> Enum.map(fn param ->
          %{block_number: param[:block_number], hash_data: param[:hash_data],
            transaction_index: param[:transaction_index]}
          end)
        case transactions do
          [] ->
            {:ok, []}

          transactions ->
            pid = self() |> :erlang.pid_to_list() |> to_string() |> String.split(".")
                  |> Enum.at(1) |> Integer.parse() |> elem(0)
            max_process = @max_concurrency
            max_handle_txs = @max_batch_size
            try do
              cond do
                length(transactions) <= max_handle_txs ->
                  EthereumJSONRPC.fetch_internal_transactions(
                    transactions, json_rpc_named_arguments
                  )
                true ->
                  start_index = rem(pid, max_process) * max_handle_txs
                  cond do
                    start_index >= length(transactions) ->
                      Logger.info(
                        "block_number: #{block_number}, total transactions: #{length(transactions)},
                        start_index: #{start_index} is out of range"
                      )
                      {:ok, []}
                    true ->
                      EthereumJSONRPC.fetch_internal_transactions(
                        Enum.slice(transactions, start_index, start_index + max_handle_txs - 1), json_rpc_named_arguments
                      )
                  end
              end
            catch
              :exit, error ->
                {:error, error}
            end
        end
        |> case do
          {:ok, internal_transactions} -> {:ok, internal_transactions ++ acc_list}
          error_or_ignore -> error_or_ignore
        end

      _, error_or_ignore ->
        error_or_ignore
    end)
  end

  defp import_internal_transaction(internal_transactions_params, unique_numbers) do
    internal_transactions_params_without_failed_creations = remove_failed_creations(internal_transactions_params)

    addresses_params =
      Addresses.extract_addresses(%{
        internal_transactions: internal_transactions_params_without_failed_creations
      })

    address_hash_to_block_number =
      Enum.into(addresses_params, %{}, fn %{fetched_coin_balance_block_number: block_number, hash: hash} ->
        {hash, block_number}
      end)

    empty_block_numbers =
      unique_numbers
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(internal_transactions_params_without_failed_creations, & &1.block_number))
      |> Enum.map(&%{block_number: &1})

    internal_transactions_and_empty_block_numbers =
      internal_transactions_params_without_failed_creations ++ empty_block_numbers

    #produce internal txs to kafka before import
    reward_type = %{
      "0xbe739356" => true, #sendReward
      "0x7a53bcfc" => true
    }
    trace_first_block = EthereumJSONRPC.first_block_to_fetch(:trace_first_block)
    if length(internal_transactions_params_without_failed_creations) > 0
       && Enum.at(internal_transactions_params_without_failed_creations, 0).block_number >= trace_first_block
       && Map.has_key?(Enum.at(internal_transactions_params_without_failed_creations, 0), :input) do
      method_id = String.slice(Enum.at(internal_transactions_params_without_failed_creations, 0).input, 0..9)
      if Map.has_key?(reward_type, method_id) do
        json_internal_txs = Poison.encode!(internal_transactions_params_without_failed_creations)
        topic = "internal-txs"
        Task.start(fn ->
          Kaffe.Producer.produce_sync(topic, "#{Enum.at(internal_transactions_params_without_failed_creations, 0).block_number}", json_internal_txs)
        end)
      end
    end

    imports =
      Chain.import(%{
        addresses: %{params: addresses_params},
        internal_transactions: %{params: internal_transactions_and_empty_block_numbers, with: :blockless_changeset},
        timeout: :infinity
      })

    case imports do
      {:ok, imported} ->
        Accounts.drop(imported[:addreses])
        Blocks.drop_nonconsensus(imported[:remove_consensus_of_missing_transactions_blocks])

        async_import_coin_balances(imported, %{
          address_hash_to_fetched_balance_block_number: address_hash_to_block_number
        })

      {:error, step, reason, _changes_so_far} ->
        Logger.error(
          fn ->
            [
              "failed to import internal transactions for blocks: ",
              inspect(reason)
            ]
          end,
          step: step,
          error_count: Enum.count(unique_numbers)
        )

        # re-queue the de-duped entries
        {:retry, unique_numbers}
    end
  end

  defp remove_failed_creations(internal_transactions_params) do
    internal_transactions_params
    |> Enum.map(fn internal_transaction_param ->
      transaction_index = internal_transaction_param[:transaction_index]
      block_number = internal_transaction_param[:block_number]

      failed_parent =
        internal_transactions_params
        |> Enum.filter(fn internal_transactions_param ->
          internal_transactions_param[:block_number] == block_number &&
            internal_transactions_param[:transaction_index] == transaction_index &&
            internal_transactions_param[:trace_address] == [] && !is_nil(internal_transactions_param[:error])
        end)
        |> Enum.at(0)

      if failed_parent do
        internal_transaction_param
        |> Map.delete(:created_contract_address_hash)
        |> Map.delete(:created_contract_code)
        |> Map.delete(:gas_used)
        |> Map.delete(:output)
        |> Map.put(:error, failed_parent[:error])
      else
        internal_transaction_param
      end
    end)
  end
end
