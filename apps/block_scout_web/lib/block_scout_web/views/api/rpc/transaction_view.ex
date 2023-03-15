defmodule BlockScoutWeb.API.RPC.TransactionView do
  use BlockScoutWeb, :view

  alias BlockScoutWeb.API.RPC.RPCView
  alias Explorer.Chain

  def render("gettxinfo.json", %{
        transaction: transaction,
        block_height: block_height,
        logs: logs
      }) do
    data = prepare_transaction(transaction, block_height, logs)
    RPCView.render("show.json", data: data)
  end

  def render("getabibytxhash.json", %{abi: abi, verified: verified}) do
    RPCView.render("show.json", data: %{"abi" => abi, "verified" => verified})
  end

  def render("getrawtracebytxhash.json", %{raw_trace: raw_trace}) do
    RPCView.render("show.json", data: %{"rawTrace" => raw_trace})
  end

  def render("gettxreceiptstatus.json", %{status: status}) do
    prepared_status = prepare_tx_receipt_status(status)
    RPCView.render("show.json", data: %{"status" => prepared_status})
  end

  def render("getstatus.json", %{error: error}) do
    RPCView.render("show.json", data: prepare_error(error))
  end

  def render("error.json", assigns) do
    RPCView.render("error.json", assigns)
  end

  defp prepare_tx_receipt_status(""), do: ""

  defp prepare_tx_receipt_status(nil), do: ""

  defp prepare_tx_receipt_status(:ok), do: "1"

  defp prepare_tx_receipt_status(_), do: "0"

  defp prepare_error("") do
    %{
      "isError" => "0",
      "errDescription" => ""
    }
  end

  defp prepare_error(error) when is_binary(error) do
    %{
      "isError" => "1",
      "errDescription" => error
    }
  end

  defp prepare_error(error) when is_atom(error) do
    %{
      "isError" => "1",
      "errDescription" => error |> Atom.to_string() |> String.replace("_", " ")
    }
  end

  defp prepare_transaction(transaction, block_height, logs) do
    {_, fee_value} = Chain.fee(transaction, :wei)
    %{
      "blockHeight" => transaction.block_number,
      "blockHash" => "#{transaction.block.hash}",
      "blockTime" => transaction.block.timestamp,
      "hash" => "#{transaction.hash}",
      "cosmosHash" => "#{transaction.cosmos_hash}",
      "confirmations" => block_height - transaction.block_number,
      "success" => if(transaction.status == :ok, do: true, else: false),
      "error" => "#{transaction.error}",
      "from" => "#{transaction.from_address_hash}",
      "fromAddressName" => Chain.get_address_name(transaction.from_address),
      "to" => "#{transaction.to_address_hash}",
      "toAddressName" => Chain.get_address_name(transaction.to_address),
      "value" => transaction.value.value,
      "input" => "#{transaction.input}",
      "gasLimit" => transaction.gas,
      "gasUsed" => transaction.gas_used,
      "gasPrice" => transaction.gas_price.value,
      "transactionFee" => fee_value,
      "cumulativeGasUsed" => transaction.cumulative_gas_used,
      "index" => transaction.index,
      "createdContractAddressHash" => to_string(transaction.created_contract_address_hash),
      "createdContractAddressName" => Chain.get_address_name(transaction.created_contract_address),
      "createdContractCodeIndexedAt" => transaction.created_contract_code_indexed_at,
      "nonce" => transaction.nonce,
      "r" => transaction.r,
      "s" => transaction.s,
      "v" => transaction.v,
      "maxPriorityFeePerGas" => parse_gas_value(transaction.max_priority_fee_per_gas),
      "maxFeePerGas" => parse_gas_value(transaction.max_fee_per_gas),
      "type" => transaction.type,
      "tokenTransfers" => Enum.map(transaction.token_transfers, &prepare_token_transfer/1),
      "logs" => Enum.map(logs, &prepare_log/1),
      "revertReason" => "#{transaction.revert_reason}"
    }
  end

  defp parse_gas_value(gas_field) do
    case gas_field do
      nil ->
        nil
      _ ->
        gas_field.value
    end
  end

  defp prepare_token_transfer(token_transfer) do
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
      "tokenId" => "#{token_transfer.token_id}",
      "tokenType" => "#{token_transfer.token.type}",
      "decimals" => "#{token_transfer.token.decimals}"
    }
  end

  defp prepare_log(log) do
    %{
      "address" => "#{log.address_hash}",
      "addressName" => "#{Chain.get_address_name(log.address)}",
      "topics" => get_topics(log) |> Enum.filter(fn log -> is_nil(log) == false end),
      "data" => "#{log.data}",
      "index" => "#{log.index}"
    }
  end

  defp get_topics(log) do
    [log.first_topic, log.second_topic, log.third_topic, log.fourth_topic]
  end
end
