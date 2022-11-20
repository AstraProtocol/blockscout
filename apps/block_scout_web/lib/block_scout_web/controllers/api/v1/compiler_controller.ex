defmodule BlockScoutWeb.API.V1.CompilerController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.API.APILogger
  alias Explorer.SmartContract.CompilerVersion
  alias Explorer.SmartContract.Solidity.CodeCompiler

  def getcompilerversions(conn, params) do
    APILogger.log(conn)

    with {:compiler_param, {:ok, compiler_param}} <- fetch_compiler(params) do
      case compiler_param do
        "solc" ->
          with {:ok, versions} <- CompilerVersion.fetch_versions(:solc) do
            send_resp(conn, :ok, result(versions))
          else
            {:error, reason} ->
              send_resp(conn, :internal_server_error, error(reason))
          end
        "vyper" ->
          with {:ok, versions} <- CompilerVersion.fetch_versions(:vyper) do
            send_resp(conn, :ok, result(versions))
          else
            {:error, reason} ->
              send_resp(conn, :internal_server_error, error(reason))
          end
        _ ->
          send_resp(conn, :internal_server_error, error("Invalid compiler"))
      end
    else
      {:compiler_param, :error} ->
        send_resp(conn, :internal_server_error, error("Query parameter compiler is required"))
    end
  end

  def getevmversions(conn, _) do
    APILogger.log(conn)

    send_resp(conn, :ok, result(CodeCompiler.allowed_evm_versions()))
  end

  def result(versions) do
    %{
      "result" => %{
        "versions" => versions
      }
    }
    |> Jason.encode!()
  end

  def error(reason) do
    %{
      "error" => reason
    }
    |> Jason.encode!()
  end

  defp fetch_compiler(params) do
    {:compiler_param, Map.fetch(params, "compiler")}
  end
end