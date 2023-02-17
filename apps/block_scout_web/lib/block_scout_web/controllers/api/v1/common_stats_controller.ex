defmodule BlockScoutWeb.API.V1.CommonStatsController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.API.APILogger
  alias Explorer.Market
  alias Explorer.ExchangeRates.Token
  alias Explorer.Counters.AverageBlockTime

  def common_stats(conn, _) do
    APILogger.log(conn)
    try do
      average_block_time = AverageBlockTime.average_block_time()
      token_stats = Market.get_exchange_rate(Explorer.coin()) || Token.null()

      send_resp(conn, :ok, result(average_block_time,
                                  token_stats
        )
      )
    rescue
      e in RuntimeError -> send_resp(conn, :internal_server_error, error(e))
    end
  end

  defp result(average_block_time, token_stats) do
    %{
      "average_block_time" => average_block_time |> Timex.Duration.to_seconds(),
      "token_stats" => %{"price" => token_stats.usd_value,
                         "volume_24h" => token_stats.volume_24h_usd,
                         "circulating_supply" => token_stats.available_supply,
                         "market_cap" => token_stats.market_cap_usd}
    }
    |> Jason.encode!()
  end

  defp error(e) do
    %{
      "error" => e
    }
    |> Jason.encode!()
  end
end