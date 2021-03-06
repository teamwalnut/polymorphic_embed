defmodule PolymorphicEmbed do
  use Ecto.ParameterizedType

  @impl true
  def type(_params), do: :map

  @impl true
  def init(opts) do
    if Keyword.get(opts, :on_replace) not in [:update, :delete] do
      raise("`:on_replace` option for polymorphic embed must be set to `:update` (single embed) or `:delete` (list of embeds)")
    end

    metadata =
      Keyword.fetch!(opts, :types)
      |> Enum.map(fn
        {type_name, type_opts} when is_list(type_opts) ->
          module = Keyword.fetch!(type_opts, :module)
          identify_by_fields = Keyword.fetch!(type_opts, :identify_by_fields)

          %{
            type: type_name |> to_string(),
            module: module,
            identify_by_fields: identify_by_fields |> Enum.map(&to_string/1)
          }

        {type_name, module} ->
          %{
            type: type_name |> to_string(),
            module: module,
            identify_by_fields: []
          }
      end)

    %{
      metadata: metadata,
      on_type_not_found: Keyword.get(opts, :on_type_not_found, :changeset_error),
      on_replace: Keyword.fetch!(opts, :on_replace)
    }
  end

  def cast_polymorphic_embed(changeset, field) do
    %{array?: array?, metadata: metadata, on_type_not_found: on_type_not_found, on_replace: on_replace} =
      get_options(changeset.data.__struct__, field)

    if array? and on_replace != :delete do
      raise "`:on_replace` option for field #{inspect field} must be set to `:update`"
    end

    if not array? and on_replace != :update do
      raise "`:on_replace` option for field #{inspect field} must be set to `:delete`"
    end

    changeset.params
    |> Map.fetch(to_string(field))
    |> case do
      :error ->
        changeset

      {:ok, nil} ->
        Ecto.Changeset.put_change(changeset, field, nil)

      {:ok, map} when map == %{} and not array? ->
        changeset

      {:ok, params_for_field} ->
        cond do
          array? and is_list(params_for_field) ->
            cast_polymorphic_embeds_many(changeset, field, params_for_field, metadata, on_type_not_found)

          not array? and is_map(params_for_field) ->
            cast_polymorphic_embeds_one(changeset, field, params_for_field, metadata, on_type_not_found)
        end
    end
  end

  defp cast_polymorphic_embeds_one(changeset, field, params, metadata, on_type_not_found) do
    params =
      Map.fetch!(changeset.data, field)
      |> case do
           nil -> %{}
           struct -> map_from_struct(struct, metadata)
         end
      |> Map.merge(params)
      |> convert_map_keys_to_string()

    case do_get_polymorphic_module(params, metadata) do
      nil when on_type_not_found == :raise ->
        raise_cannot_infer_type_from_data(params)

      nil when on_type_not_found == :changeset_error ->
        Ecto.Changeset.add_error(changeset, field, "is invalid")

      module ->
        module.changeset(struct(module), params)
        |> case do
           %{valid?: true} = embed_changeset ->
             Ecto.Changeset.put_change(
               changeset,
               field,
               Ecto.Changeset.apply_changes(embed_changeset)
             )

           %{valid?: false} = embed_changeset ->
             changeset
             |> Ecto.Changeset.put_change(field, embed_changeset)
             |> Map.put(:valid?, false)
         end
    end
  end

  defp cast_polymorphic_embeds_many(changeset, field, list_params, metadata, on_type_not_found) do
    embeds =
      Enum.map(list_params, fn params ->
        case do_get_polymorphic_module(params, metadata) do
          nil when on_type_not_found == :raise ->
            raise_cannot_infer_type_from_data(params)

          nil when on_type_not_found == :changeset_error ->
           :error

          module ->
            module.changeset(struct(module), params)
            |> case do
               %{valid?: true} = embed_changeset ->
                 Ecto.Changeset.apply_changes(embed_changeset)

               %{valid?: false} = embed_changeset ->
                 embed_changeset
             end
        end
      end)

    if Enum.any?(embeds, &(&1 == :error)) do
      Ecto.Changeset.add_error(changeset, field, "is invalid")
    else
      any_invalid? = Enum.any?(embeds, fn
        %{valid?: false} -> true
        _ -> false
      end)

      Ecto.Changeset.put_change(changeset, field, embeds)
      |> Map.put(:valid?, !any_invalid?)
    end
  end

  @impl true
  def cast(_data, _params),
    do:
      raise(
        "#{__MODULE__} must not be casted using Ecto.Changeset.cast/4, use #{__MODULE__}.cast_polymorphic_embed/2 instead."
      )

  @impl true
  def embed_as(_format, _params), do: :dump

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(data, _loader, %{metadata: metadata}) do
    case do_get_polymorphic_module(data, metadata) do
      nil -> raise_cannot_infer_type_from_data(data)
      module when is_atom(module) -> {:ok, Ecto.embedded_load(module, data, :json)}
    end
  end

  @impl true
  def dump(%Ecto.Changeset{valid?: false}, _dumper, _params) do
    raise "cannot dump invalid changeset"
  end

  def dump(%_module{} = struct, dumper, %{metadata: metadata}) do
    dumper.(:map, map_from_struct(struct, metadata))
  end

  def dump(nil, dumper, _params) do
    dumper.(:map, nil)
  end

  defp map_from_struct(%module{} = struct, metadata) do
    struct
    |> Ecto.embedded_dump(:json)
    |> Map.put(:__type__, do_get_polymorphic_type(module, metadata))
  end

  def get_polymorphic_module(schema, field, type_or_data) do
    %{metadata: metadata} = get_options(schema, field)
    do_get_polymorphic_module(type_or_data, metadata)
  end

  defp do_get_polymorphic_module(%{:__type__ => type}, metadata),
    do: do_get_polymorphic_module(type, metadata)

  defp do_get_polymorphic_module(%{"__type__" => type}, metadata),
    do: do_get_polymorphic_module(type, metadata)

  defp do_get_polymorphic_module(%{} = attrs, metadata) do
    # check if one list is contained in another
    # Enum.count(contained -- container) == 0
    # contained -- container == []
    metadata
    |> Enum.filter(&([] != &1.identify_by_fields))
    |> Enum.find(&([] == &1.identify_by_fields -- Map.keys(attrs)))
    |> (&(&1 && Map.fetch!(&1, :module))).()
  end

  defp do_get_polymorphic_module(type, metadata) do
    type = to_string(type)

    metadata
    |> Enum.find(&(type == &1.type))
    |> (&(&1 && Map.fetch!(&1, :module))).()
  end

  def get_polymorphic_type(schema, field, module_or_struct) do
    %{metadata: metadata} = get_options(schema, field)
    do_get_polymorphic_type(module_or_struct, metadata)
  end

  defp do_get_polymorphic_type(%module{}, metadata),
    do: do_get_polymorphic_type(module, metadata)

  defp do_get_polymorphic_type(module, metadata) do
    metadata
    |> Enum.find(&(module == &1.module))
    |> Map.fetch!(:type)
    |> String.to_atom()
  end

  defp get_options(schema, field) do
    try do
      schema.__schema__(:type, field)
    rescue
      _ in UndefinedFunctionError ->
        raise ArgumentError, "#{inspect(schema)} is not an Ecto schema"
    else
      {:parameterized, PolymorphicEmbed, options} -> Map.put(options, :array?, false)
      {:array, {:parameterized, PolymorphicEmbed, options}} -> Map.put(options, :array?, true)
      {_, {:parameterized, PolymorphicEmbed, options}} -> Map.put(options, :array?, false)
      nil -> raise ArgumentError, "#{field} is not an Ecto.Enum field"
    end
  end

  defp convert_map_keys_to_string(%{} = map),
    do: for({key, val} <- map, into: %{}, do: {to_string(key), val})

  defp raise_cannot_infer_type_from_data(data),
    do: raise("could not infer polymorphic embed from data #{inspect(data)}")
end
