defmodule Beamcore.Agent.Tools.ImageGeneration do
  @moduledoc """
  Generates images through a configured image provider and saves them to the workspace.
  """

  alias Beamcore.Agent.Providers
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Generate an image with the configured image provider and save it to a
  workspace-relative output path. The default provider is Mistral, using Agents
  with the built-in image_generation tool. This tool performs real API calls and
  remains subject to workspace path safety and project policy.
  """

  def name, do: "image_generation"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            prompt: %{
              type: "string",
              description: "Detailed image prompt to send to the image provider"
            },
            output_path: %{
              type: "string",
              description:
                "Workspace-relative path where the generated image should be saved, " <>
                  "usually ending in .png"
            },
            provider: %{
              type: "string",
              description: "Optional image provider. Currently supported: mistral"
            },
            instructions: %{
              type: "string",
              description:
                "Optional provider instructions for style, project context, or constraints"
            },
            model: %{
              type: "string",
              description: "Optional provider model"
            },
            agent_id: %{
              type: "string",
              description:
                "Optional existing Mistral image agent ID. If omitted, " <>
                  "MISTRAL_IMAGE_AGENT_ID or a temporary agent is used"
            }
          },
          required: ["prompt", "output_path"]
        }
      }
    }
  end

  def execute(params) when is_map(params) do
    with {:ok, _prompt} <- required_string(params, "prompt"),
         {:ok, output_path} <- required_string(params, "output_path"),
         :ok <- ProjectPolicy.allowed_write_path?(output_path),
         {:ok, absolute_output_path} <- PathSafety.resolve(output_path, allow_missing: true),
         {:ok, files} <- Providers.ImageGeneration.generate(params),
         {:ok, saved_paths} <- save_files(files, absolute_output_path) do
      Jason.encode!(%{
        ok: true,
        summary: "Generated #{length(saved_paths)} image file(s).",
        files: saved_paths,
        file_ids: Enum.map(files, & &1.file_id)
      })
    else
      {:error, reason} -> "Error: #{reason}"
    end
  end

  def execute(_params), do: "Error: image_generation parameters must be an object."

  defp save_files(files, absolute_output_path) do
    absolute_output_path |> Path.dirname() |> File.mkdir_p!()

    files
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, paths} ->
      path = output_path_for(absolute_output_path, index, length(files), file)

      with {:ok, bytes} <- image_bytes_from_file(file),
           :ok <- validate_image_bytes(bytes, file),
           :ok <- File.write(path, bytes) do
        relative = Path.relative_to(path, PathSafety.workspace_root())
        {:cont, {:ok, paths ++ [relative]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp image_bytes_from_file(%{bytes: bytes}) when is_binary(bytes),
    do: normalize_download_payload(bytes)

  defp image_bytes_from_file(file) do
    {:error, "Generated file #{inspect(file.file_id)} did not include downloadable bytes."}
  end

  defp normalize_download_payload(bytes) when is_binary(bytes) do
    cond do
      image_bytes?(bytes) ->
        {:ok, bytes}

      String.starts_with?(String.trim_leading(bytes), "{") ->
        decode_json_image_payload(bytes)

      true ->
        {:ok, bytes}
    end
  end

  defp decode_json_image_payload(bytes) do
    case Jason.decode(bytes) do
      {:ok, json} -> decode_json_image_fields(json)
      {:error, _error} -> {:ok, bytes}
    end
  end

  defp decode_json_image_fields(json) when is_map(json) do
    encoded =
      Map.get(json, "base64") ||
        Map.get(json, "b64_json") ||
        Map.get(json, "bytes") ||
        Map.get(json, "content") ||
        Map.get(json, "data")

    decode_possible_base64(encoded, json)
  end

  defp decode_json_image_fields(_json), do: {:ok, ""}

  defp decode_possible_base64(nil, json), do: {:ok, Jason.encode!(json)}

  defp decode_possible_base64("data:" <> data_uri, _json) do
    case String.split(data_uri, ",", parts: 2) do
      [_metadata, encoded] -> decode_base64(encoded)
      _parts -> {:ok, "data:" <> data_uri}
    end
  end

  defp decode_possible_base64(encoded, _json) when is_binary(encoded), do: decode_base64(encoded)
  defp decode_possible_base64(_encoded, json), do: {:ok, Jason.encode!(json)}

  defp decode_base64(encoded) do
    encoded = String.trim(encoded)

    case Base.decode64(encoded) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        case Base.url_decode64(encoded, padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:ok, encoded}
        end
    end
  end

  defp validate_image_bytes(bytes, file) when is_binary(bytes) and byte_size(bytes) > 16 do
    if image_bytes?(bytes) do
      :ok
    else
      preview =
        bytes
        |> binary_part(0, min(byte_size(bytes), 120))
        |> inspect(printable_limit: 120)

      message =
        "Downloaded file #{inspect(file.file_id)} is not a valid image payload. " <>
          "Preview: #{preview}"

      {:error, message}
    end
  end

  defp validate_image_bytes(_bytes, file) do
    {:error, "Downloaded file #{inspect(file.file_id)} is empty or too small to be an image."}
  end

  defp image_bytes?(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: true
  defp image_bytes?(<<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  defp image_bytes?(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: true
  defp image_bytes?(_bytes), do: false

  defp output_path_for(path, _index, 1, _file), do: path

  defp output_path_for(path, index, _count, file) do
    extension = file_extension(file) || extension_or_default(path)
    root = Path.rootname(path)
    "#{root}_#{index}#{extension}"
  end

  defp extension_or_default(path) do
    case Path.extname(path) do
      "" -> ".png"
      extension -> extension
    end
  end

  defp file_extension(%{file_type: type}) when is_binary(type) and type != "" do
    normalized =
      type
      |> String.downcase()
      |> String.trim_leading(".")

    extension =
      case normalized do
        "image/png" -> "png"
        "image/jpeg" -> "jpg"
        "image/jpg" -> "jpg"
        "image/webp" -> "webp"
        other -> other
      end

    ".#{extension}"
  end

  defp file_extension(%{file_name: name}) when is_binary(name) do
    case Path.extname(name) do
      "" -> nil
      extension -> extension
    end
  end

  defp file_extension(_file), do: nil

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

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
