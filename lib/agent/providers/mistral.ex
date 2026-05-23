defmodule Beamcore.Agent.Providers.Mistral do
  @moduledoc """
  Mistral image generation provider.

  Mistral image generation is exposed as a built-in Agents/Conversations tool:
  create or reuse an agent with `tools: [%{type: "image_generation"}]`, start a
  conversation, extract `tool_file` chunks, and download each generated file.
  """

  alias Beamcore.Agent.OpenAI

  @default_model "mistral-medium-latest"

  @default_instructions """
  Use the image_generation tool to create the requested image.
  Return the generated image file.
  """

  @spec generate_image(map()) :: {:ok, [map()]} | {:error, binary()}
  def generate_image(params) when is_map(params) do
    with {:ok, prompt} <- required_string(params, "prompt"),
         {:ok, agent_id} <- image_agent_id(params),
         {:ok, conversation} <- start_conversation(agent_id, prompt),
         {:ok, files} <- extract_tool_files(conversation),
         {:ok, downloaded_files} <- download_files(files) do
      {:ok, downloaded_files}
    end
  end

  def generate_image(_params), do: {:error, "Mistral image parameters must be an object."}

  defp image_agent_id(params) do
    case string_param(params, "agent_id") || env("MISTRAL_IMAGE_AGENT_ID") do
      nil -> create_image_agent(params)
      agent_id -> {:ok, agent_id}
    end
  end

  defp create_image_agent(params) do
    model = string_param(params, "model") || env("MISTRAL_IMAGE_MODEL") || @default_model
    instructions = string_param(params, "instructions") || @default_instructions

    payload = %{
      model: model,
      name: "Beamcore Image Generation Agent",
      description: "Temporary agent used by Beamcore.Agent to generate images.",
      instructions: instructions,
      tools: [%{type: "image_generation"}],
      completion_args: %{temperature: 0.3, top_p: 0.95}
    }

    with {:ok, body} <- OpenAI.post_json("/agents", payload),
         {:ok, json} <- Jason.decode(body),
         agent_id when is_binary(agent_id) <- Map.get(json, "id") do
      {:ok, agent_id}
    else
      nil -> {:error, "Mistral agent creation response did not include an agent id."}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Unable to parse Mistral agent creation response."}
    end
  end

  defp start_conversation(agent_id, prompt) do
    payload = %{agent_id: agent_id, inputs: prompt}

    with {:ok, body} <- OpenAI.post_json("/conversations", payload),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Unable to parse Mistral conversation response."}
    end
  end

  defp extract_tool_files(response) do
    files =
      response
      |> collect_tool_files()
      |> Enum.uniq_by(& &1.file_id)

    case files do
      [] -> {:error, "Mistral response did not include generated image file IDs."}
      files -> {:ok, files}
    end
  end

  defp collect_tool_files(%{"type" => "tool_file", "file_id" => file_id} = map)
       when is_binary(file_id) do
    [
      %{
        file_id: file_id,
        file_name: Map.get(map, "file_name"),
        file_type: Map.get(map, "file_type")
      }
    ]
  end

  defp collect_tool_files(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.flat_map(&collect_tool_files/1)
  end

  defp collect_tool_files(list) when is_list(list) do
    Enum.flat_map(list, &collect_tool_files/1)
  end

  defp collect_tool_files(_value), do: []

  defp download_files(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case OpenAI.get_binary("/files/#{file.file_id}/content") do
        {:ok, bytes} ->
          {:cont, {:ok, acc ++ [Map.put(file, :bytes, bytes)]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp required_string(params, key) do
    case string_param(params, key) do
      nil -> {:error, "#{key} is required."}
      value -> {:ok, value}
    end
  end

  defp string_param(params, key) do
    params
    |> Map.get(key)
    |> normalize_string()
  end

  defp env(name), do: System.get_env(name) |> normalize_string()

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
