defmodule Module.Types do
  @moduledoc false

  defmodule Error do
    defexception [:message]
  end

  import Module.Types.Helpers
  alias Module.Types.{Expr, Pattern, Unify}

  @doc false
  def warnings(module, file, defs, no_warn_undefined, cache) do
    stack = stack()

    Enum.flat_map(defs, fn {{fun, arity} = function, kind, meta, clauses} ->
      context = context(with_file_meta(meta, file), module, function, no_warn_undefined, cache)

      Enum.flat_map(clauses, fn {_meta, args, guards, body} ->
        def_expr = {kind, meta, [guards_to_expr(guards, {fun, [], args})]}

        try do
          warnings_from_clause(args, guards, body, def_expr, stack, context)
        rescue
          e ->
            def_expr = {kind, meta, [guards_to_expr(guards, {fun, [], args}), [do: body]]}

            error =
              Error.exception("""
              found error while checking types for #{Exception.format_mfa(module, fun, arity)}

              #{Macro.to_string(def_expr)}

              Please report this bug: https://github.com/elixir-lang/elixir/issues

              #{Exception.format_banner(:error, e, __STACKTRACE__)}\
              """)

            reraise error, __STACKTRACE__
        end
      end)
    end)
  end

  defp with_file_meta(meta, file) do
    case Keyword.fetch(meta, :file) do
      {:ok, {meta_file, _}} -> meta_file
      :error -> file
    end
  end

  defp guards_to_expr([], left) do
    left
  end

  defp guards_to_expr([guard | guards], left) do
    guards_to_expr(guards, {:when, [], [left, guard]})
  end

  defp warnings_from_clause(args, guards, body, def_expr, stack, context) do
    head_stack = Unify.push_expr_stack(def_expr, stack)

    with {:ok, _types, context} <- Pattern.of_head(args, guards, head_stack, context),
         {:ok, _type, context} <- Expr.of_expr(body, :dynamic, stack, context) do
      context.warnings
    else
      {:error, {type, error, context}} ->
        [error_to_warning(type, error, context) | context.warnings]
    end
  end

  @doc false
  def context(file, module, function, no_warn_undefined, cache) do
    %{
      # File of module
      file: file,
      # Module of definitions
      module: module,
      # Current function
      function: function,
      # List of calls to not warn on as undefined
      no_warn_undefined: no_warn_undefined,
      # A list of cached modules received from the parallel compiler
      cache: cache,
      # Expression variable to type variable
      vars: %{},
      # Type variable to expression variable
      types_to_vars: %{},
      # Type variable to type
      types: %{},
      # Trace of all variables that have been refined to a type,
      # including the type they were refined to, why, and where
      traces: %{},
      # Counter to give type variables unique names
      counter: 0,
      # Track if a variable was inferred from a type guard function such is_tuple/1
      # or a guard function that fails such as elem/2, possible values are:
      # `:guarded` when `is_tuple(x)`
      # `:guarded` when `is_tuple and elem(x, 0)`
      # `:fail` when `elem(x, 0)`
      guard_sources: %{},
      # A list with all warnings from the running the code
      warnings: []
    }
  end

  @doc false
  def stack() do
    %{
      # Stack of variables we have refined during unification,
      # used for creating relevant traces
      unify_stack: [],
      # Last expression we have recursed through during inference,
      # used for tracing
      last_expr: nil,
      # When false do not add a trace when a type variable is refined,
      # useful when merging contexts where the variables already have traces
      trace: true,
      # There are two factors that control how we track guards.
      #
      # * consider_type_guards?: if type guards should be considered.
      #   This applies only at the root and root-based "and" and "or" nodes.
      #
      # * keep_guarded? - if a guarded clause should remain as guarded
      #   even on failure. Used on the right side of and.
      #
      type_guards: {_consider_type_guards? = true, _keep_guarded? = false},
      # Context used to determine if unification is bi-directional, :expr
      # is directional, :pattern is bi-directional
      context: nil
    }
  end

  ## ERROR TO WARNING

  # Collect relevant information from context and traces to report error
  def error_to_warning(:unable_apply, {mfa, args, expected, signature, stack}, context) do
    {fun, arity} = context.function
    location = {context.file, get_line(stack), {context.module, fun, arity}}

    traces = type_traces(stack, context)
    {[signature | args], traces} = lift_all_types([signature | args], traces, context)
    error = {:unable_apply, mfa, args, expected, signature, {location, stack.last_expr, traces}}
    {Module.Types, error, location}
  end

  def error_to_warning(:unable_unify, {left, right, stack}, context) do
    {fun, arity} = context.function
    location = {context.file, get_line(stack), {context.module, fun, arity}}

    traces = type_traces(stack, context)
    {[left, right], traces} = lift_all_types([left, right], traces, context)
    error = {:unable_unify, left, right, {location, stack.last_expr, traces}}
    {Module.Types, error, location}
  end

  defp get_line(stack), do: stack.last_expr |> get_meta() |> Keyword.get(:line, 0)

  # Collect relevant traces from context.traces using stack.unify_stack
  defp type_traces(stack, context) do
    # TODO: Do we need the unify_stack or is enough to only get the last variable
    #       in the stack since we get related variables anyway?
    stack =
      stack.unify_stack
      |> Enum.flat_map(&[&1 | related_variables(&1, context.types)])
      |> Enum.uniq()

    Enum.flat_map(stack, fn var_index ->
      with %{^var_index => traces} <- context.traces,
           %{^var_index => expr_var} <- context.types_to_vars do
        Enum.map(traces, &tag_trace(expr_var, &1, context))
      else
        _other -> []
      end
    end)
  end

  defp related_variables(var, types) do
    Enum.flat_map(types, fn
      {related_var, {:var, ^var}} ->
        [related_var | related_variables(related_var, types)]

      _ ->
        []
    end)
  end

  # Tag if trace is for a concrete type or type variable
  defp tag_trace(var, {type, expr, location}, context) do
    with {:var, var_index} <- type,
         %{^var_index => expr_var} <- context.types_to_vars do
      {:var, var, expr_var, expr, location}
    else
      _ -> {:type, var, type, expr, location}
    end
  end

  defp lift_all_types(types, traces, context) do
    trace_types = for({:type, _, type, _, _} <- traces, do: type)
    {types, lift_context} = Unify.lift_types(types, context)
    {trace_types, _lift_context} = Unify.lift_types(trace_types, lift_context)

    {traces, []} =
      Enum.map_reduce(traces, trace_types, fn
        {:type, var, _, expr, location}, [type | acc] -> {{:type, var, type, expr, location}, acc}
        other, acc -> {other, acc}
      end)

    {types, traces}
  end

  ## FORMAT WARNINGS

  def format_warning({:unable_apply, mfa, args, expected, signature, {location, expr, traces}}) do
    {original_module, original_function, arity} = mfa
    {_, _, args} = mfa_or_fa = erl_to_ex(original_module, original_function, args, [])
    {module, function, ^arity} = call_to_mfa(mfa_or_fa)
    format_mfa = Exception.format_mfa(module, function, arity)
    {traces, [] = _hints} = format_traces(traces, [], false)

    clauses =
      Enum.map(signature, fn {ins, out} ->
        {_, _, ins} = erl_to_ex(original_module, original_function, ins, [])

        {:fun, [{ins, out}]}
        |> Unify.format_type(false)
        |> IO.iodata_to_binary()
        |> binary_slice(1..-2//1)
      end)

    [
      "expected #{format_mfa} to have signature:\n\n    ",
      Enum.map_join(args, ", ", &Unify.format_type(&1, false)),
      " -> #{Unify.format_type(expected, false)}",
      "\n\nbut it has signature:\n\n    ",
      indent(Enum.join(clauses, "\n")),
      "\n\n",
      format_expr(expr, location),
      traces,
      "Conflict found at"
    ]
  end

  def format_warning({:unable_unify, left, right, {location, expr, traces}}) do
    if map_type?(left) and map_type?(right) and match?({:ok, _, _}, missing_field(left, right)) do
      {:ok, atom, known_atoms} = missing_field(left, right)

      # Drop the last trace which is the expression map.foo
      traces = Enum.drop(traces, 1)
      {traces, hints} = format_traces(traces, [left, right], true)

      [
        "undefined field \"#{atom}\" ",
        format_expr(expr, location),
        "expected one of the following fields: ",
        Enum.map_join(Enum.sort(known_atoms), ", ", & &1),
        "\n\n",
        traces,
        format_message_hints(hints),
        "Conflict found at"
      ]
    else
      simplify_left? = simplify_type?(left, right)
      simplify_right? = simplify_type?(right, left)

      {traces, hints} = format_traces(traces, [left, right], simplify_left? or simplify_right?)

      [
        "incompatible types:\n\n    ",
        Unify.format_type(left, simplify_left?),
        " !~ ",
        Unify.format_type(right, simplify_right?),
        "\n\n",
        format_expr(expr, location),
        traces,
        format_message_hints(hints),
        "Conflict found at"
      ]
    end
  end

  defp missing_field(
         {:map, [{:required, {:atom, atom} = type, _}, {:optional, :dynamic, :dynamic}]},
         {:map, fields}
       ) do
    matched_missing_field(fields, type, atom)
  end

  defp missing_field(
         {:map, fields},
         {:map, [{:required, {:atom, atom} = type, _}, {:optional, :dynamic, :dynamic}]}
       ) do
    matched_missing_field(fields, type, atom)
  end

  defp missing_field(_, _), do: :error

  defp matched_missing_field(fields, type, atom) do
    if List.keymember?(fields, type, 1) do
      :error
    else
      known_atoms = for {_, {:atom, atom}, _} <- fields, do: atom
      {:ok, atom, known_atoms}
    end
  end

  defp format_traces([], _types, _simplify?) do
    {[], []}
  end

  defp format_traces(traces, types, simplify?) do
    traces
    |> Enum.uniq()
    |> Enum.reverse()
    |> Enum.map_reduce([], fn
      {:type, var, type, expr, location}, hints ->
        {hint, hints} = format_type_hint(type, types, expr, hints)

        trace = [
          "where \"",
          Macro.to_string(var),
          "\" was given the type ",
          Unify.format_type(type, simplify?),
          hint,
          " in:\n\n    # ",
          format_location(location),
          "    ",
          indent(expr_to_string(expr)),
          "\n\n"
        ]

        {trace, hints}

      {:var, var1, var2, expr, location}, hints ->
        trace = [
          "where \"",
          Macro.to_string(var1),
          "\" was given the same type as \"",
          Macro.to_string(var2),
          "\" in:\n\n    # ",
          format_location(location),
          "    ",
          indent(expr_to_string(expr)),
          "\n\n"
        ]

        {trace, hints}
    end)
  end

  defp format_location({file, line, _mfa}) do
    format_location({file, line})
  end

  defp format_location({file, line}) do
    file = Path.relative_to_cwd(file)
    line = if line, do: [Integer.to_string(line)], else: []
    [file, ?:, line, ?\n]
  end

  defp simplify_type?(type, other) do
    map_like_type?(type) and not map_like_type?(other)
  end

  ## EXPRESSION FORMATTING

  defp format_expr(nil, _location) do
    []
  end

  defp format_expr(expr, location) do
    [
      "in expression:\n\n    # ",
      format_location(location),
      "    ",
      indent(expr_to_string(expr)),
      "\n\n"
    ]
  end

  @doc false
  def expr_to_string(expr) do
    expr
    |> reverse_rewrite()
    |> Macro.to_string()
  end

  defp reverse_rewrite(guard) do
    Macro.prewalk(guard, fn
      {{:., _, [mod, fun]}, meta, args} -> erl_to_ex(mod, fun, args, meta)
      other -> other
    end)
  end

  defp erl_to_ex(mod, fun, args, meta) do
    case :elixir_rewrite.erl_to_ex(mod, fun, args) do
      {Kernel, fun, args} -> {fun, meta, args}
      {mod, fun, args} -> {{:., [], [mod, fun]}, meta, args}
    end
  end

  ## Hints

  defp format_message_hints(hints) do
    hints
    |> Enum.uniq()
    |> Enum.reverse()
    |> Enum.map(&[format_message_hint(&1), "\n"])
  end

  defp format_message_hint(:inferred_dot) do
    """
    HINT: "var.field" (without parentheses) implies "var" is a map() while \
    "var.fun()" (with parentheses) implies "var" is an atom()
    """
  end

  defp format_message_hint(:inferred_bitstring_spec) do
    """
    HINT: all expressions given to binaries are assumed to be of type \
    integer() unless said otherwise. For example, <<expr>> assumes "expr" \
    is an integer. Pass a modifier, such as <<expr::float>> or <<expr::binary>>, \
    to change the default behaviour.
    """
  end

  defp format_message_hint({:sized_and_unsize_tuples, {size, var}}) do
    """
    HINT: use pattern matching or "is_tuple(#{Macro.to_string(var)}) and \
    tuple_size(#{Macro.to_string(var)}) == #{size}" to guard a sized tuple.
    """
  end

  defp format_type_hint(type, types, expr, hints) do
    case format_type_hint(type, types, expr) do
      {message, hint} -> {message, [hint | hints]}
      :error -> {[], hints}
    end
  end

  defp format_type_hint(type, types, expr) do
    cond do
      dynamic_map_dot?(type, expr) ->
        {" (due to calling var.field)", :inferred_dot}

      dynamic_remote_call?(type, expr) ->
        {" (due to calling var.fun())", :inferred_dot}

      inferred_bitstring_spec?(type, expr) ->
        {[], :inferred_bitstring_spec}

      message = sized_and_unsize_tuples(expr, types) ->
        {[], {:sized_and_unsize_tuples, message}}

      true ->
        :error
    end
  end

  defp dynamic_map_dot?(type, expr) do
    with true <- map_type?(type),
         {{:., _meta1, [_map, _field]}, meta2, []} <- expr,
         true <- Keyword.get(meta2, :no_parens, false) do
      true
    else
      _ -> false
    end
  end

  defp dynamic_remote_call?(type, expr) do
    with true <- atom_type?(type),
         {{:., _meta1, [_module, _field]}, meta2, []} <- expr,
         false <- Keyword.get(meta2, :no_parens, false) do
      true
    else
      _ -> false
    end
  end

  defp inferred_bitstring_spec?(type, expr) do
    with true <- integer_type?(type),
         {:<<>>, _, args} <- expr,
         true <- Enum.any?(args, &match?({:"::", [{:inferred_bitstring_spec, true} | _], _}, &1)) do
      true
    else
      _ -> false
    end
  end

  defp sized_and_unsize_tuples({{:., _, [:erlang, :is_tuple]}, _, [var]}, types) do
    case Enum.find(types, &match?({:tuple, _, _}, &1)) do
      {:tuple, size, _} ->
        {size, var}

      nil ->
        nil
    end
  end

  defp sized_and_unsize_tuples(_expr, _types) do
    nil
  end

  ## Formatting helpers

  defp indent(string) do
    String.replace(string, "\n", "\n    ")
  end

  defp map_type?({:map, _}), do: true
  defp map_type?(_other), do: false

  defp map_like_type?({:map, _}), do: true
  defp map_like_type?({:union, union}), do: Enum.any?(union, &map_like_type?/1)
  defp map_like_type?(_other), do: false

  defp atom_type?(:atom), do: true
  defp atom_type?({:atom, _}), do: false
  defp atom_type?({:union, union}), do: Enum.all?(union, &atom_type?/1)
  defp atom_type?(_other), do: false

  defp integer_type?(:integer), do: true
  defp integer_type?(_other), do: false

  defp call_to_mfa({{:., _, [mod, fun]}, _, args}), do: {mod, fun, length(args)}
  defp call_to_mfa({fun, _, args}) when is_atom(fun), do: {Kernel, fun, length(args)}
end
