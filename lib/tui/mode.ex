defmodule Beamcore.TUI.Mode do
  @moduledoc """
  A switchable top-level surface of the TUI shell.

  Modes are the tabs in the mode bar. `:chat` and `:dashboard` are live; the
  remaining modes are registered placeholders that render a "coming soon" body,
  so the shell can grow new surfaces by adding a registry entry rather than
  reworking layout.
  """

  @enforce_keys [:id, :fkey, :key_label, :name, :status]
  defstruct [:id, :fkey, :key_label, :name, :status]

  @type status :: :ready | :coming_soon

  @type t :: %__MODULE__{
          id: atom(),
          fkey: String.t(),
          key_label: String.t(),
          name: String.t(),
          status: status()
        }

  alias Beamcore.TUI.Glyphs

  @doc "All modes, in mode-bar / F-key order."
  @spec all() :: [t()]
  def all do
    [
      %__MODULE__{id: :chat, fkey: "f1", key_label: "F1", name: "Chat", status: :ready},
      %__MODULE__{id: :dashboard, fkey: "f2", key_label: "F2", name: "Dashboard", status: :ready},
      %__MODULE__{
        id: :research,
        fkey: "f3",
        key_label: "F3",
        name: "Research",
        status: :coming_soon
      }
    ]
  end

  @doc "The mode shown on launch."
  @spec default_id() :: atom()
  def default_id, do: :chat

  @doc "Looks up a mode by id, raising when the id is unknown."
  @spec fetch!(atom()) :: t()
  def fetch!(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> raise KeyError, key: id, term: __MODULE__
      mode -> mode
    end
  end

  @doc "Returns the mode bound to an F-key code (e.g. `\"f2\"`), or nil when unbound."
  @spec by_fkey(String.t()) :: t() | nil
  def by_fkey(fkey), do: Enum.find(all(), &(&1.fkey == fkey))

  @doc "Zero-based position of a mode, as the Tabs widget's `selected` index."
  @spec index(atom()) :: non_neg_integer() | nil
  def index(id), do: Enum.find_index(all(), &(&1.id == id))

  @doc "Whether a mode is a registered placeholder rather than a live surface."
  @spec coming_soon?(t()) :: boolean()
  def coming_soon?(%__MODULE__{status: :coming_soon}), do: true
  def coming_soon?(%__MODULE__{}), do: false

  @doc ~S"""
  The mode bar label, e.g. `"F1 Chat"` or, when coming soon, `"F3 ···"`.

  A selected coming-soon tab reveals its real name (`"F3 Research"`) so the
  reader can see which placeholder they are on; pass `active?: true` for that.
  The placeholder falls back to `"..."` on non-unicode terminals.
  """
  @spec tab_title(t(), boolean(), boolean()) :: String.t()
  def tab_title(mode, active? \\ false, unicode? \\ true)

  def tab_title(%__MODULE__{key_label: key_label} = mode, active?, unicode?) do
    "#{key_label} #{display_name(mode, active?, unicode?)}"
  end

  defp display_name(%__MODULE__{status: :coming_soon}, false, unicode?),
    do: Glyphs.placeholder(unicode?)

  defp display_name(%__MODULE__{name: name}, _active?, _unicode?), do: name
end
