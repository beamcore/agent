defmodule Beamcore.Agent.Tools.Eeva.AtomBudget do
  @moduledoc false
  use GenServer

  @default_per_call 512
  @default_total 32_768
  @persistent_key {__MODULE__, :admitted_identifiers}
  @identifier_source "[\\p{L}_][\\p{L}\\p{N}_]*[!?]?"
  @identifier Regex.compile!(@identifier_source, "u")
  @whole_identifier Regex.compile!("^" <> @identifier_source <> "$", "u")

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec admit(binary()) :: :ok | {:error, binary()}
  def admit(code) when is_binary(code) do
    admit_identifiers(candidate_identifiers(code))
  end

  @doc false
  @spec admit_identifiers([binary()]) :: :ok | {:error, binary()}
  def admit_identifiers(identifiers) when is_list(identifiers) do
    candidates =
      identifiers
      |> Enum.filter(&safe_identifier?/1)
      |> Enum.uniq()

    case Process.whereis(__MODULE__) do
      nil ->
        {:error, "Eeva atom budget service is not available."}

      _pid ->
        GenServer.call(__MODULE__, {:admit, candidates})
    end
  end

  @impl true
  def init(_opts) do
    admitted = :persistent_term.get(@persistent_key, MapSet.new())
    {:ok, %{admitted: admitted}}
  end

  @impl true
  def handle_call({:admit, candidates}, _from, state) do
    per_call = Beamcore.Config.get_setting(:eeva_max_new_atoms_per_call, @default_per_call)
    total = Beamcore.Config.get_setting(:eeva_max_total_new_atoms, @default_total)

    unknown =
      candidates
      |> Enum.reject(&existing_atom?/1)
      |> MapSet.new()
      |> MapSet.difference(state.admitted)
      |> MapSet.to_list()

    cond do
      length(unknown) > per_call ->
        {:reply,
         {:error,
          "Eeva code introduces #{length(unknown)} new identifiers; the per-call limit is #{per_call}."},
         state}

      MapSet.size(state.admitted) + length(unknown) > total ->
        {:reply,
         {:error,
          "Eeva identifier budget is exhausted; the process-wide limit is #{total} new identifiers."},
         state}

      true ->
        Enum.each(unknown, &String.to_atom/1)
        admitted = Enum.reduce(unknown, state.admitted, &MapSet.put(&2, &1))
        :persistent_term.put(@persistent_key, admitted)
        {:reply, :ok, %{state | admitted: admitted}}
    end
  end

  defp candidate_identifiers(code) do
    code = strip_non_code_text(code)

    @identifier
    |> Regex.scan(code)
    |> Enum.map(&hd/1)
    |> Enum.reject(&(byte_size(&1) > 128))
    |> Enum.uniq()
  end

  defp strip_non_code_text(code) do
    code = Regex.replace(~r/""".*?"""|'''.*?'''/s, code, " ")
    code = Regex.replace(~r/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/s, code, " ")
    Regex.replace(~r/#.*$/m, code, " ")
  end

  defp safe_identifier?(identifier) when is_binary(identifier) do
    byte_size(identifier) <= 128 and Regex.match?(@whole_identifier, identifier)
  end

  defp safe_identifier?(_identifier), do: false

  defp existing_atom?(identifier) do
    _ = String.to_existing_atom(identifier)
    true
  rescue
    ArgumentError -> false
  end
end
