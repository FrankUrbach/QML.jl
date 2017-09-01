module QML

export @emit, @qmlfunction, @qmlapp, qmlfunction, QVariant, load, QQmlPropertyMap, set_context_object

@static if is_windows()
  ENV["QML_PREFIX_PATH"] = joinpath(dirname(dirname(@__FILE__)),"deps","usr")
end

using CxxWrap
using Observables
using FileIO

FileIO.add_format(format"QML", (), ".qml")

const depsfile = joinpath(dirname(dirname(@__FILE__)), "deps", "deps.jl")
if !isfile(depsfile)
  error("$depsfile not found, package QML did not build properly")
end
include(depsfile)

const envfile = joinpath(dirname(dirname(@__FILE__)), "deps", "env.jl")
if isfile(envfile)
  include(envfile)
end

"""
QVariant type encapsulation
"""
immutable QVariant
  value::Any
end

wrap_module(_l_qml_wrap, QML)

load
function FileIO.load(f::FileIO.File{format"QML"}, ctxobj::QObject)
  qml_engine = init_qmlapplicationengine()
  ctx = root_context(qml_engine)
  set_context_object(ctx, ctxobj)
  if !load_into_engine(qml_engine, filename(f))
    error("Failed to load QML file ", filename(f))
  end
  gcprotect(ctxobj)
  return qml_engine
end

"""

load(qml_file, prop1=x, prop2=y, ...)

Load a QML file, creating a QQmlApplicationEngine and setting the context properties supplied in the keyword arguments. Returns the created engine.

load(qml_file, context_object)

Load a QML file, creating a QQmlApplicationEngine and setting the context object to the supplied QObject
"""
function FileIO.load(f::FileIO.File{format"QML"}; kwargs...)
  qml_engine = init_qmlapplicationengine()
  ctx = root_context(qml_engine)
  propmap = QQmlPropertyMap(ctx)
  set_context_object(ctx, propmap)
  for (key,value) in kwargs
    propmap[String(key)] = value
  end
  if !load_into_engine(qml_engine, filename(f))
    error("Failed to load QML file ", filename(f))
  end
  return qml_engine
end

function __init__()
  # Make sure we have an application at module load, so any QObject is created after this
  @static if is_windows()
    libdir = joinpath(dirname(dirname(@__FILE__)),"deps","usr","lib")
    for fname in readdir(libdir)
      if endswith(fname, ".dll")
        Libdl.dlopen(joinpath(libdir,fname), Libdl.RTLD_GLOBAL)
      end
    end
  end
end

# Functor to update a QML property when an Observable is changed in Julia
immutable QmlPropertyUpdater
  propertymap::QQmlPropertyMap
  key::String
end
function (updater::QmlPropertyUpdater)(x)
  updater.propertymap[updater.key] = x
end

# Predicate to find out if a handler is a QML updater
noqmlupdater(::Any) = true
noqmlupdater(::QmlPropertyUpdater) = false

# Called from C++ to update an Observable linked to a QML property
function update_observable_property!(o::Observable, v)
  # This avoids calling the to-qml update handler, since we initiated the update from QML
  Observables.setexcludinghandlers(o, v, noqmlupdater)
end

# QQmlPropertyMap indexing interface
Base.getindex(propmap::QQmlPropertyMap, key::AbstractString) = value(propmap, key).value
function Base.setindex!{T}(propmap::QQmlPropertyMap, val::T, key::AbstractString)
  if !isbits(T) && !isimmutable(T)
    gcprotect(val)
  end
  insert(propmap, key, QVariant(val))
end
Base.setindex!(propmap::QQmlPropertyMap, val::QVariant, key::AbstractString) = insert(propmap, key, val)
function Base.setindex!(propmap::QQmlPropertyMap, val::Observable, key::AbstractString)
  insert_observable(propmap, key, val)
  on(QmlPropertyUpdater(propmap, key), val)
end
Base.setindex!(propmap::QQmlPropertyMap, val::Irrational, key::AbstractString) = (propmap[key] = convert(Float64, val))

"""
Expand an expression of the form a.b.c to replace the dot operator by function calls:
`@expand_dots a.b.c.d f` returns `f(f(f(a,"b"),"c"),"d")`
"""
macro expand_dots(source_expr, func)
  if source_expr.head == :escape
    source_expr = source_expr.args[1]
  end
  if isa(source_expr, Expr) && source_expr.head == :(.)
    return :($func(@expand_dots($(esc(source_expr.args[1])), $func), $(string(source_expr.args[2].args[1]))))
  end
  return esc(source_expr)
end

"""
Set a property on the given context
"""
function set_context_property(ctx::QQmlContext, key::AbstractString, value)
  invoke(set_context_property, Tuple{QQmlContext, AbstractString, QVariant}, ctx, key, QVariant(value))
end

# Specialize for Reals
function set_context_property(ctx::QQmlContext, key::AbstractString, value::Real)
  invoke(set_context_property, Tuple{QQmlContext, AbstractString, Any}, ctx, key, convert(Float64,value))
  return
end

# Ambiguity resolution
function set_context_property(ctx::QML.QQmlContext, key::AbstractString, value::Union{CxxWrap.SmartPointer{T2}, T2} where T2<:QML.QObject)
  return invoke(set_context_property, Tuple{Union{CxxWrap.SmartPointer{T2}, T2} where T2<:QML.QQmlContext, AbstractString, QObject}, ctx, key, value)
end

"""
Emit a signal in the form:
```
@emit signal_name(arg1, arg2)
```
"""
macro emit(expr)
  esc(:(emit($(string(expr.args[1])), Any[$(expr.args[2:end]...)])))
end

"""
Register a Julia function for access from QML:
```
@qmlfunction MyFunc
```
"""
macro qmlfunction(fnames...)
  result = quote end
  for fname in fnames
    push!(result.args, :(qmlfunction($(esc(string(fname))), $(esc(fname)))))
  end

  return result
end

"""
Load the given QML path using a QQmlApplicationEngine, initializing the context with the given properties. Deprecated
"""
macro qmlapp(path, context_properties...)
  Base.depwarn("The qmlapp macro is deprecated. Please use the qmlapp function instead and add properties separately using either @contextproperties or the global context object.", :qmlapp)
  result = quote
    qml_engine = init_qmlapplicationengine()
  end
  for p in context_properties
    push!(result.args, :(set_context_property(qmlcontext(), $(esc(string(p))), $(esc(p)))))
  end
  push!(result.args, :(load_into_engine(qml_engine, $(esc(path)))))
  return result
end

function qmlapp(path::AbstractString)
  qml_engine = init_qmlapplicationengine()
  return load_into_engine(qml_engine, path)
end

function Base.display(d::JuliaDisplay, x)
  buf = IOBuffer()
  Base.show(buf, MIME"image/png"(), x)
  load_png(d, take!(buf))
end

function Base.displayable(d::JuliaDisplay, mime::AbstractString)
  if mime == "image/png"
    return true
  end
  return false
end

glvisualize_include() = joinpath(dirname(@__FILE__), "glvisualize_callbacks.jl")

"""
Constructor for ListModel that automatically copies a typed array into an Array{Any,1} and creates a constructor and setter and getter functions for each field if addroles == true
"""
function ListModel{T}(a::Array{T}, addroles=true)
  any_array = Array{Any,1}(a)
  function update_array()
    n = length(any_array)
    resize!(a,n)
    for i = 1:n
      a[i] = any_array[i]
    end
  end

  listmodel = ListModel(any_array, update_array)

  if nfields(T) > 0 && addroles
    for fname in fieldnames(T)
      addrole(listmodel, string(fname), (x) -> getfield(x, fname), (array, value, index) -> setfield!(array[index], fname, value))
    end
    setconstructor(listmodel, T)
  end

  return listmodel
end

@doc """
Module for building [Qt5 QML](http://doc.qt.io/qt-5/qtqml-index.html) graphical user interfaces for Julia programs.
Types starting with `Q` are equivalent of their Qt C++ counterpart, so they have no Julia docstring and we refer to
the [Qt documentation](http://doc.qt.io/qt-5/qtqml-index.html) for details instead.
""" QML

@doc """
Equivalent to [`QQmlContext::setContextProperty`](http://doc.qt.io/qt-5/qqmlcontext.html#setContextProperty).

This function is useful to expose Julia values to  Current properties can be fundamental numeric types,
strings and any `QObject`.

Example:
```julia
qml_engine = QQmlApplicationEngine()
root_ctx = root_context(qml_engine)
set_context_property(root_ctx, "my_property", 1)
```

You can now use `my_property` in QML and every time `set_context_property` is called on it the GUI gets notified.
""" set_context_property

@doc "Equivalent to [`QQmlEngine::rootContext`](http://doc.qt.io/qt-5/qqmlengine.html#rootContext)" root_context

@doc "Equivalent to `QLibraryInfo::location(QLibraryInfo::PrefixPath)`" qt_prefix_path
@doc "Equivalent to `QQuickWindow::contentItem`" content_item
@doc "Equivalent to `QQuickView::setSource`" set_source
@doc "Equivalent to `QQuickView::show`" show
@doc "Equivalent to `QQuickView::engine`" engine
@doc "Equivalent to `QQuickView::rootObject`" root_object

@doc """
Equivalent to `QQmlComponent::setData`. Use this to set the QML code for a QQmlComponent from a Julia string literal.
""" set_data

@doc """
Equivalent to `QQmlComponent::create`. This creates a component defined by the QML code set using `set_data`.
It also makes sure the newly created object is parented to the given context.
""" create

@doc """
qmlfunction(name, function)

Register the given function using the given name. Useful for registering functions from a non-exported module or renaming a function upon register (e.g. removing the !)

""" qmlfunction

end
