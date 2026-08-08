defmodule PlaidEx.Schemas.LinkToken do
  @moduledoc "Response from /link/token/create."

  @type t :: %__MODULE__{
          link_token: String.t(),
          expiration: String.t(),
          request_id: String.t()
        }

  defstruct [:link_token, :expiration, :request_id]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      link_token: map["link_token"],
      expiration: map["expiration"],
      request_id: map["request_id"]
    }
  end
end
