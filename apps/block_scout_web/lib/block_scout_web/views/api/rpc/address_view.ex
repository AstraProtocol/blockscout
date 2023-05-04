defmodule BlockScoutWeb.API.RPC.AddressView do
  use BlockScoutWeb, :view

  alias Explorer.Chain.{Address}
  alias Explorer.Chain
  alias BlockScoutWeb.API.EthRPC.View, as: EthRPCView
  alias BlockScoutWeb.API.RPC.RPCView

  def render("listaccounts.json", %{accounts: accounts}) do
    accounts = Enum.map(accounts, &prepare_account/1)
    RPCView.render("show.json", data: accounts)
  end

  def render("getaddress.json", %{address_detail: address_detail, verified: verified}) do
    contractName = Chain.get_address_name(address_detail)
    creationTransaction = prepare_creation_transaction(address_detail)
    creator = prepare_creator(address_detail)
    {implementation_address_hash, implementation_address_name} =
      if address_detail.smart_contract && address_detail.smart_contract.abi do
        Chain.get_implementation_address_hash(address_detail.hash, address_detail.smart_contract.abi)
      else
        {"", ""}
      end
    data = %{
      "contractName" => contractName,
      "balance" => (address_detail.fetched_coin_balance && address_detail.fetched_coin_balance.value) || "0",
      "tokenName" => to_string(address_detail.token && address_detail.token.name),
      "tokenSymbol" => to_string(address_detail.token && address_detail.token.symbol),
      "creationTransaction" => creationTransaction,
      "creator" => creator,
      "implementationAddressName" => implementation_address_name || "",
      "implementationAddressHash" =>
        if(implementation_address_hash == "0x0000000000000000000000000000000000000000", do: "", else: implementation_address_hash || ""),
      "lastBalanceUpdate" => address_detail.fetched_coin_balance_block_number,
      "type" => get_address_type(creator),
      "verified" => verified
    }
    RPCView.render("show.json", data: data)
  end

  def render("balance.json", %{addresses: [address]}) do
    RPCView.render("show.json",
      data: %{balance: balance(address), lastBalanceUpdate: address.fetched_coin_balance_block_number}
    )
  end

  def render("balance.json", assigns) do
    render("balancemulti.json", assigns)
  end

  def render("balancemulti.json", %{addresses: addresses}) do
    data = Enum.map(addresses, &render_address/1)

    RPCView.render("show.json", data: data)
  end

  def render("pendingtxlist.json", %{transactions: transactions}) do
    data = Enum.map(transactions, &prepare_pending_transaction/1)
    RPCView.render("show.json", data: data)
  end

  def render("txlist.json", %{
    transactions: transactions, has_next_page: has_next_page, next_page_path: next_page_path}) do
    data = %{
      "result" => Enum.map(transactions, &prepare_transaction/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("txlistinternal.json", %{internal_transactions: internal_transactions}) do
    data = Enum.map(internal_transactions, &prepare_internal_transaction/1)
    RPCView.render("show.json", data: data)
  end

  def render("txlistinternalpagination.json", %{
    internal_transactions: internal_transactions, has_next_page: has_next_page, next_page_path: next_page_path}) do
    data = %{
      "result" => Enum.map(internal_transactions, &prepare_internal_transaction/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("tokentx.json", %{token_transfers: token_transfers}) do
    data = Enum.map(token_transfers, &prepare_token_transfer/1)
    RPCView.render("show.json", data: data)
  end

  def render("tokenbalance.json", %{token_balance: token_balance}) do
    RPCView.render("show.json", data: to_string(token_balance))
  end

  def render("token_list.json", %{
    token_list: tokens, has_next_page: has_next_page, next_page_path: next_page_path}) do
    data = %{
      "result" => Enum.map(tokens, &prepare_token/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("getlisttokentransfers.json", %{
    token_transfers: token_transfers, has_next_page: has_next_page, next_page_path: next_page_path}) do
    data = %{
      "result" => Enum.map(token_transfers, &prepare_common_token_transfer_for_api/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("getlogs.json", %{
    logs: logs, has_next_page: has_next_page, next_page_path: next_page_path}) do
    data = %{
      "result" => Enum.map(logs, &prepare_log/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("getminedblocks.json", %{blocks: blocks}) do
    data = Enum.map(blocks, &prepare_block/1)
    RPCView.render("show.json", data: data)
  end

  def render("gettopaddressesbalance.json", %{
      top_addresses_balance: items, has_next_page: has_next_page, next_page_path: next_page_path})
    do
    data = %{
      "result" => Enum.map(items, &prepare_top_addresses_balance/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("getcoinbalancehistory.json", %{
      coin_balances: coin_balances, has_next_page: has_next_page, next_page_path: next_page_path})
    do
    data = %{
      "result" => Enum.map(coin_balances, &prepare_coin_balance_history/1),
      "hasNextPage" => has_next_page,
      "nextPagePath" => next_page_path
    }
    RPCView.render("show_data.json", data: data)
  end

  def render("getaddresscounters.json", %{
      transaction_count: transactions_from_db,
      token_transfer_count: token_transfers_from_db,
      gas_usage_count: address_gas_usage_from_db,
      validation_count: validation_count,
      address: address})
    do
    creator = prepare_creator(address)
    data = %{
      "transactionCount" => transactions_from_db,
      "tokenTransferCount" => token_transfers_from_db,
      "gasUsageCount" => address_gas_usage_from_db,
      "validationCount" => validation_count,
      "type" => get_address_type(creator),
    }
    RPCView.render("show.json", data: data)
  end

  def render("eth_get_balance.json", %{balance: balance}) do
    EthRPCView.render("show.json", %{result: balance, id: 0})
  end

  def render("eth_get_balance_error.json", %{error: message}) do
    EthRPCView.render("error.json", %{error: message, id: 0})
  end

  def render("error.json", assigns) do
    RPCView.render("error.json", assigns)
  end

  defp render_address(address) do
    %{
      "account" => "#{address.hash}",
      "balance" => balance(address),
      "stale" => address.stale? || false
    }
  end

  defp prepare_top_addresses_balance(item) do
    address = item[:address]
    txn_count = item[:tx_count]
    %{
      "balance" => to_string(address.fetched_coin_balance && address.fetched_coin_balance.value),
      "address" => to_string(address.hash),
      "txnCount" => txn_count
    }
  end

  defp prepare_coin_balance_history(coin_balance) do
    %{
      "addressHash" => coin_balance.address_hash,
      "blockNumber" => coin_balance.block_number,
      "blockTimestamp" => coin_balance.block_timestamp,
      "delta" => coin_balance.delta,
      "insertedAt" => coin_balance.inserted_at,
      "transactionHash" => coin_balance.transaction_hash,
      "transactionValue" => to_string(coin_balance.transaction_value && coin_balance.transaction_value.value),
      "updatedAt" => coin_balance.updated_at,
      "value" => to_string(coin_balance.value && coin_balance.value.value),
      "valueFetchedAt" => coin_balance.value_fetched_at
    }
  end

  defp prepare_account(address) do
    %{
      "balance" => to_string(address.fetched_coin_balance && address.fetched_coin_balance.value),
      "address" => to_string(address.hash),
      "stale" => address.stale? || false
    }
  end

  defp prepare_pending_transaction(transaction) do
    %{
      "hash" => "#{transaction.hash}",
      "nonce" => "#{transaction.nonce}",
      "from" => "#{transaction.from_address_hash}",
      "to" => "#{transaction.to_address_hash}",
      "value" => "#{transaction.value.value}",
      "gas" => "#{transaction.gas}",
      "gasPrice" => "#{transaction.gas_price.value}",
      "input" => "#{transaction.input}",
      "contractAddress" => "#{transaction.created_contract_address_hash}",
      "cumulativeGasUsed" => "#{transaction.cumulative_gas_used}",
      "gasUsed" => "#{transaction.gas_used}"
    }
  end

  defp prepare_transaction(transaction) do
    %{
      "blockNumber" => "#{transaction.block_number}",
      "timeStamp" => "#{DateTime.to_unix(transaction.block.timestamp)}",
      "hash" => "#{transaction.hash}",
      "cosmosHash" => "#{transaction.cosmos_hash}",
      "blockHash" => "#{transaction.block_hash}",
      "from" => "#{transaction.from_address_hash}",
      "fromAddressName" => Chain.get_address_name(transaction.from_address),
      "to" => "#{transaction.to_address_hash}",
      "toAddressName" => Chain.get_address_name(transaction.to_address),
      "value" => "#{transaction.value.value}",
      "gas" => "#{transaction.gas}",
      "gasPrice" => "#{transaction.gas_price.value}",
      "cumulativeGasUsed" => "#{transaction.cumulative_gas_used}",
      "gasUsed" => "#{transaction.gas_used}",
      "success" => if(transaction.status == :ok, do: true, else: false),
      "error" => "#{transaction.error}",
      "createdContractAddressHash" => "#{transaction.created_contract_address_hash}",
      "contractMethodName" => Chain.get_contract_method_name_by_input_data(transaction.input) || "",
      "input" => "#{transaction.input}"
    }
  end

  defp prepare_internal_transaction(internal_transaction) do
    %{
      "blockNumber" => "#{internal_transaction.block_number}",
      "timeStamp" => "#{DateTime.to_unix(internal_transaction.transaction.block.timestamp)}",
      "from" => "#{internal_transaction.from_address_hash}",
      "fromAddressName" => Chain.get_address_name(internal_transaction.from_address),
      "to" => "#{internal_transaction.to_address_hash}",
      "toAddressName" => Chain.get_address_name(internal_transaction.to_address),
      "value" => "#{internal_transaction.value.value}",
      "contractAddress" => "#{internal_transaction.created_contract_address_hash}",
      "transactionHash" => to_string(internal_transaction.transaction_hash),
      "index" => to_string(internal_transaction.index),
      "input" => "#{internal_transaction.input}",
      "type" => "#{internal_transaction.type}",
      "callType" => "#{internal_transaction.call_type}",
      "gas" => "#{internal_transaction.gas}",
      "gasUsed" => "#{internal_transaction.gas_used}",
      "isError" => if(internal_transaction.error, do: "1", else: "0"),
      "errCode" => "#{internal_transaction.error}"
    }
  end

  defp prepare_common_token_transfer_for_api(tx) do
    %{
      "blockNumber" => tx.block_number,
      "timeStamp" => to_string(DateTime.to_unix(tx.block.timestamp)),
      "hash" => to_string(tx.hash),
      "nonce" => tx.nonce,
      "blockHash" => to_string(tx.block.hash),
      "from" => to_string(tx.from_address_hash),
      "fromAddressName" => Chain.get_address_name(tx.from_address),
      "to" => to_string(tx.to_address_hash),
      "toAddressName" => Chain.get_address_name(tx.to_address),
      "tokenTransfers" => Enum.map(tx.token_transfers,
        fn token_transfer -> prepare_token_transfer_for_api(token_transfer) end),
      "transactionIndex" => tx.index,
      "gas" => tx.gas,
      "gasPrice" => tx.gas_price.value,
      "gasUsed" => tx.gas_used,
      "cumulativeGasUsed" => tx.cumulative_gas_used,
      "input" => tx.input,
      "contractMethodName" => Chain.get_contract_method_name_by_input_data(tx.input) || ""
    }
  end

  defp prepare_common_token_transfer(token_transfer) do
    %{
      "blockNumber" => to_string(token_transfer.block_number),
      "timeStamp" => to_string(DateTime.to_unix(token_transfer.block_timestamp)),
      "hash" => to_string(token_transfer.transaction_hash),
      "nonce" => to_string(token_transfer.transaction_nonce),
      "blockHash" => to_string(token_transfer.block_hash),
      "from" => to_string(token_transfer.from_address_hash),
      "contractAddress" => to_string(token_transfer.token_contract_address_hash),
      "to" => to_string(token_transfer.to_address_hash),
      "logIndex" => to_string(token_transfer.token_log_index),
      "tokenName" => token_transfer.token_name,
      "tokenSymbol" => token_transfer.token_symbol,
      "tokenDecimal" => to_string(token_transfer.token_decimals),
      "transactionIndex" => to_string(token_transfer.transaction_index),
      "gas" => to_string(token_transfer.transaction_gas),
      "gasPrice" => to_string(token_transfer.transaction_gas_price.value),
      "gasUsed" => to_string(token_transfer.transaction_gas_used),
      "cumulativeGasUsed" => to_string(token_transfer.transaction_cumulative_gas_used),
      "input" => to_string(token_transfer.transaction_input),
      "confirmations" => to_string(token_transfer.confirmations)
    }
  end

  defp prepare_token_transfer(%{token_type: "ERC-721"} = token_transfer) do
    token_transfer
    |> prepare_common_token_transfer()
    |> Map.put_new(:tokenID, token_transfer.token_id)
  end

  defp prepare_token_transfer(%{token_type: "ERC-1155"} = token_transfer) do
    token_transfer
    |> prepare_common_token_transfer()
    |> Map.put_new(:tokenID, token_transfer.token_id)
  end

  defp prepare_token_transfer(%{token_type: "ERC-20"} = token_transfer) do
    token_transfer
    |> prepare_common_token_transfer()
    |> Map.put_new(:value, to_string(token_transfer.amount))
  end

  defp prepare_token_transfer(token_transfer) do
    prepare_common_token_transfer(token_transfer)
  end

  defp prepare_token_transfer_for_api(token_transfer) do
    %{
      "amount" => "#{token_transfer.amount}",
      "logIndex" => "#{token_transfer.log_index}",
      "fromAddress" => "#{token_transfer.from_address}",
      "fromAddressName" => Chain.get_address_name(token_transfer.from_address),
      "toAddress" => "#{token_transfer.to_address}",
      "toAddressName" => Chain.get_address_name(token_transfer.to_address),
      "tokenContractAddress" => "#{token_transfer.token_contract_address}",
      "tokenName" => "#{token_transfer.token.name}",
      "tokenSymbol" => "#{token_transfer.token.symbol}",
      "decimals" => "#{token_transfer.token.decimals}"
    }
  end

  defp prepare_block(block) do
    %{
      "blockNumber" => to_string(block.number),
      "timeStamp" => to_string(block.timestamp)
    }
  end

  defp prepare_token(token_balances) do
    {%Address.CurrentTokenBalance{
      token_id: token_id,
      value: value,
      token: token
    }, _} = token_balances
    %{
      "balance" => value,
      "contractAddress" => to_string(token.contract_address_hash),
      "name" => token.name,
      "decimals" => token.decimals,
      "symbol" => token.symbol,
      "type" => token.type
    }
    |> (&if(is_nil(token_id), do: &1, else: Map.put(&1, "id", token_id))).()
  end

  defp balance(address) do
    address.fetched_coin_balance && address.fetched_coin_balance.value && "#{address.fetched_coin_balance.value}"
  end

  defp prepare_log(log) do
    %{
      "transaction" => to_string(log.transaction.hash),
      "topics" => get_topics(log) |> Enum.filter(fn log -> is_nil(log) == false end),
      "data" => to_string(log.data)
    }
  end

  defp get_topics(log) do
    [log.first_topic, log.second_topic, log.third_topic, log.fourth_topic]
  end

  defp prepare_creation_transaction(address_detail) do
    if is_nil(address_detail.contracts_creation_internal_transaction) do
      to_string(address_detail.contracts_creation_transaction && address_detail.contracts_creation_transaction.hash)
    else
      try do
        to_string(
          address_detail.contracts_creation_internal_transaction &&
            address_detail.contracts_creation_internal_transaction.transaction_hash
        )
      rescue
        KeyError -> ""
      end
    end
  end

  def prepare_creator(address_detail) do
    if is_nil(address_detail.contracts_creation_internal_transaction) do
      to_string(address_detail.contracts_creation_transaction &&
        address_detail.contracts_creation_transaction.from_address_hash
      )
    else
      try do
        to_string(
          address_detail.contracts_creation_internal_transaction &&
            address_detail.contracts_creation_internal_transaction.from_address_hash
        )
      rescue
        KeyError -> ""
      end
    end
  end

  def get_address_type(creator) do
    if creator == "" do
      "address"
    else
      "contractaddress"
    end
  end
end
