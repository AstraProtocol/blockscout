# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

config :indexer,
  ecto_repos: [Explorer.Repo]

# config :indexer, Indexer.Fetcher.ReplacedTransaction.Supervisor, disabled?: true

config :indexer, Indexer.Tracer,
  service: :indexer,
  adapter: SpandexDatadog.Adapter,
  trace_key: :blockscout

config :logger, :indexer,
  # keep synced with `config/config.exs`
  format: "$dateT$time $metadata[$level] $message\n",
  metadata:
    ~w(application fetcher request_id first_block_number last_block_number missing_block_range_count missing_block_count
       block_number step count error_count shrunk import_id transaction_id)a,
  metadata_filter: [application: :indexer]

kafka_topic = System.get_env("KAFKA_TOPIC") || "evm-txs"
kafka_brokers = System.get_env("KAFKA_BROKERS")
endpoints = case kafka_brokers do
  nil ->
    [{String.to_charlist("localhost"), 9092}]
  _ ->
    list_urls = kafka_brokers |> String.split(",")
    Enum.map(list_urls, fn url ->
      [ip, port] = url |> String.trim |> String.split(":")
      {ip |> String.to_charlist(), port |> String.to_integer()}
    end)
end

config :kaffe,
  producer: [
    endpoints: endpoints,
    topics: [kafka_topic],

    # optional
    partition_strategy: :md5,
    ssl: true,
    sasl: %{
      mechanism: :plain,
      login: System.get_env("KAFFE_PRODUCER_USER"),
      password: System.get_env("KAFFE_PRODUCER_PASSWORD")
    }
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
