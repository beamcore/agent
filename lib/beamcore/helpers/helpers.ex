defmodule Beamcore.Helpers do
  @moduledoc """
  Safe runtime introspection helpers for Eeva programs.

  These helpers expose metadata that already exists in loaded BeamCore modules;
  they do not register a separate model-facing tool or create atoms from user
  supplied strings.
  """

  @allowed_info_keys [:functions, :macros, :attributes, :compile, :md5, :module]

  def info(module, key) when is_atom(module) and key in @allowed_info_keys do
    ensure_beamcore_module!(module)
    module.__info__(key)
  end

  def docs(module) when is_atom(module) do
    ensure_beamcore_module!(module)

    case Code.fetch_docs(module) do
      {:docs_v1, annotation, language, format, moduledoc, metadata, docs} ->
        %{
          annotation: annotation,
          language: language,
          format: format,
          moduledoc: moduledoc,
          metadata: metadata,
          docs: normalize_docs(docs)
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  def modules(prefix \\ "Beamcore") when is_binary(prefix) do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(fn module -> String.starts_with?(Atom.to_string(module), "Elixir." <> prefix) end)
    |> Enum.sort()
  end

  defp ensure_beamcore_module!(module) do
    name = Atom.to_string(module)

    unless String.starts_with?(name, "Elixir.Beamcore") do
      raise ArgumentError, "Only Beamcore modules may be inspected through Beamcore.Helpers."
    end

    module
  end

  defp normalize_docs(docs) do
    Enum.map(docs, fn {{kind, name, arity}, annotation, signature, doc, metadata} ->
      %{
        kind: kind,
        name: name,
        arity: arity,
        annotation: annotation,
        signature: signature,
        doc: doc,
        metadata: metadata
      }
    end)
  end
end
