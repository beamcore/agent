defmodule Beamcore.Agent.MockCompletions do
  def create(client, params) do
    case Process.get(:mock_completions_create) ||
           Application.get_env(:beamcore, :mock_completions_create) do
      nil ->
        # Default mock response for general completions
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => "This is a mock assistant response."
               }
             }
           ]
         }}

      fun when is_function(fun) ->
        fun.(client, params)
    end
  end
end
