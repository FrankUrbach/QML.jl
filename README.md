# QML

[![Build Status](https://travis-ci.org/barche/QML.jl.svg?branch=master)](https://travis-ci.org/barche/QML.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/7edud4w38g8m17yw?svg=true)](https://ci.appveyor.com/project/barche/qml-jl)

This package provides an interface to [Qt5 QML](http://qt.io/). It uses the [`CxxWrap`](https://github.com/barche/CxxWrap.jl) package to expose C++ classes. Current functionality allows interaction between QML and Julia using basic numerical and string types, as well as display of PNG images and a very experimental OpenGL rendering element (see `example/gltriangle.jl`).

![QML plots example](example/plot.png?raw=true "Plots example")

![OpenGL example](example/gltriangle.gif?raw=true "OpenGL example, using GLAbstraction.jl")

## Installation
The current master version is experimental for Julia 1.0, and no binaries are available yet. Please build the binary part from [JlQml](https://github.com/barche/jlqml) first, and then set the `JLQML_DIR` environment variable to the path to the jlqml build directory. After that, run, in pkg mode:
```text
add QML#master
```

On Linux and macOS, compilation should be automatic, with dependencies installed by the packagemanager or Homebrew.jl. On Windows, binaries are downloaded. To use a non-standard Qt, set the environment variable `QT_ROOT` to the base Qt directory (the one containing `lib` and `bin` on macOS and linux, or the directory containing `msvc2015_64` or `msvc2015` on Windows).

You can check that the correct Qt version is used using the `qt_prefix_path()` function.

### Raspberry Pi
Because of issues with LLVM library compatibility between the graphics driver on the Raspberry Pi and Julia, QML.jl will only work if you build Julia from source, using the system LLVM version 3.9. Install the `llvm-3.9-dev` package, and then build Julia with the following Make.user:

```
override LLVM_CONFIG=llvm-config-3.9
override USE_SYSTEM_LLVM=1
```

## Usage
### Running examples
To run the included examples, execute:
```julia
include(joinpath(Pkg.dir("QML"), "example", "runexamples.jl"))
```
The examples require some additional packages to be described by the manifest and project files in the examples directory, so from the examples directory you should
start Julia with `julia --project` and then run `instantiate` from the pkg shell.

### Loading a QML file
We support three methods of loading a QML file: `QQmlApplicationEngine`, `QQuickView` and `QQmlComponent`. These behave equivalently to the corresponding Qt classes.
#### QQmlApplicationEngine
The easiest way to run the QML file `main.qml` from the current directory is using the `load` function, which will create and return a `QQmlApplicationEngine` and load the supplied QML file:
```julia
using QML
load("main.qml")
exec()
```

The lifetime of the `QQmlApplicationEngine` is managed from C++ and it gets cleaned up when the application quits. This means it is not necessary to keep a reference to the engine to prevent it from being garbage collected prematurely.

#### QQuickView
The `QQuickView` creates a window, so it's not necessary to wrap the QML in `ApplicationWindow`. A QML file is loaded as follows:

```julia
qview = init_qquickview()
set_source(qview, "main.qml")
QML.show(qview)
exec()
```

#### QQmlComponent
Using `QQmlComponent` the QML code can be set from a Julia string wrapped in `QByteArray`:

```julia
qml_data = QByteArray("""
import ...

ApplicationWindow {
  ...
}
""")

qengine = init_qmlengine()
qcomp = QQmlComponent(qengine)
set_data(qcomp, qml_data, "")
create(qcomp, qmlcontext());

# Run the application
exec()
```

## Interacting with Julia
Interaction with Julia happens through the following mechanisms:
* Call Julia functions from QML
* Read and set context properties from Julia and QML
* Emit signals from Julia to QML
* Use data models

Note that Julia slots appear missing, but they are not needed since it is possible to directly connect a Julia function to a QML signal in the QML code (see the QTimer example below).

### Calling Julia functions
In Julia, functions are registered using the `qmlfunction` function:
```julia
my_function() = "Hello from Julia"
my_other_function(a, b) = "Hi from Julia"

qmlfunction("my_function", my_function)
qmlfunction("my_other_function", my_other_function)
```

For convenience, there is also a macro that registers any number of functions that are in scope and will have the same name in QML as in Julia:
```julia
@qmlfunction my_function my_other_function
```

However, the macro cannot be used in the case of non-exported functions from a different module or in case the function contains a `!` character.

In QML, include the Julia API:
```qml
import org.julialang 1.0
```

Then call a Julia function in QML using:
```qml
Julia.my_function()
Julia.my_other_function(arg1, arg2)
```

### Context properties
Context properties are set using the context object method. To dynamically add properties from Julia, a `QQmlPropertyMap` is used, setting e.g. a property named `a`:
```julia
propmap = QML.QQmlPropertyMap()
propmap["a"] = 1
```

This sets the QML context property named `property_name` to value `julia_value`.

The value of a property can be queried from Julia like this:
```julia
@test propmap["a"] == 1
```

To pass these properties to the QML side, the property map can be the second argument to `load`:
```julia
load(qml_file, propmap)
```

There is also a shorthand notation using keywords:
```julia
load(qml_file, a=1, b=2)
```
This will create context properties `a` and `b`, initialized to `1` and `2`.

#### Observable properties
When an [`Observable`](https://github.com/JuliaGizmos/Observables.jl) is set in a `QQmlPropertyMap`, bi-directional change notification is enabled. For example, using the Julia code:
```julia
using QML
using Observables

const qml_file = "observable.qml"
const input = Observable(1.0)
const output = Observable(0.0)

on(output) do x
  println("Output changed to ", x)
end

load(qml_file, input=input, output=output)
exec_async() # run from REPL for async execution
```

In QML we add a slider for the input and display the output, which is twice the input (computed in QML here):
```qml
import QtQuick 2.0
import QtQuick.Controls 1.0
import QtQuick.Layouts 1.0

ApplicationWindow {
  id: root
  title: "Observables"
  width: 512
  height: 200
  visible: true

  ColumnLayout {
    spacing: 6
    anchors.fill: parent

    Slider {
      value: input
      Layout.alignment: Qt.AlignCenter
      Layout.fillWidth: true
      minimumValue: 0.0
      maximumValue: 100.0
      stepSize: 1.0
      tickmarksEnabled: true
      onValueChanged: {
        input = value;
        output = 2*input;
      }
    }

    Text {
      Layout.alignment: Qt.AlignCenter
      text: output
      font.pixelSize: 0.1*root.height
    }
  }

}
```

Moving the slider will print the output on Julia. The input can also be set from the REPL using e.g. `input[] = 3.0`, and the slider will move accordingly and call QML to compute the output, which can be queried using `output[]`.

#### Type conversion
Most fundamental types are converted implicitly. Mind that the default integer type in QML corresponds to `Int32` in Julia.

We also convert `QVariantMap`, exposing the indexing operator `[]` to access element by a string key. This mostly to deal with arguments passed to the QML `append` function in list models.

### Emitting signals from Julia
Defining signals must be done in QML in the JuliaSignals block, following the instructions from the [QML manual](http://doc.qt.io/qt-5/qtqml-syntax-objectattributes.html#signal-attributes). Example signal with connection:
```qml
JuliaSignals {
  signal fizzBuzzFound(int fizzbuzzvalue)
  onFizzBuzzFound: lastFizzBuzz.text = fizzbuzzvalue
}
```

The above signal is emitted from Julia using simply:
```julia
@emit fizzBuzzFound(i)
```

**There must never be more than one JuliaSignals block in QML**

### Using data models
#### ListModel
The `ListModel` type allows using data in QML views such as `ListView` and `Repeater`, providing a two-way synchronization of the data. The [dynamiclist](http://doc.qt.io/qt-5/qtquick-views-listview-dynamiclist-qml.html) example from Qt has been translated to Julia in `example/dynamiclist.jl`. As can be seen from [this commit](https://github.com/barche/QML.jl/commit/5f3e64579180fb913c47d92a438466b67098ee52), the only required change was moving the model data from QML to Julia, otherwise the Qt-provided QML file is left unchanged.

A ListModel is constructed from a 1D Julia array. In Qt, each of the elements of a model has a series of roles, available as properties in the delegate that is used to display each item. The roles can be added using the `addrole` function, for example:
```julia
julia_array = ["A", 1, 2.2]
myrole(x::AbstractString) = lowercase(x)
myrole(x::Number) = Int(round(x))

array_model = ListModel(julia_array)
addrole(array_model, "myrole", myrole, setindex!)
```
adds the role named `myrole` to `array_model`, using the function `myrole` to access the value. The `setindex!` argument is a function used to set the value for that role from QML. This argument is optional, if it is not provided the role will be read-only. The arguments of this setter are `collection, new_value, key` as in the standard `setindex!` function.

To use the model from QML, it can be exposed as a context attribute, e.g:
```julia
load(qml_file, array_model=array_model)
```

And then in QML:
```qml
ListView {
  width: 200
  height: 125
  model: array_model
  delegate: Text { text: myrole }
}
```

If no roles are added, one default role named `string` is exposed, calling the Julia function `string` to convert whatever value in the array to a string.

If new elements need to be constructed from QML, a constructor can also be provided, using the `setconstructor` method, taking a `ListModel` and a Julia function as arguments, e.g. just setting identity to return the constructor argument:
```julia
setconstructor(array_model, identity)
```

In the dynamiclist example, the entries in the model are all "fruits", having the roles name, cost and attributes. In Julia, this can be encapsulated in a composite type:
```julia
mutable struct Fruit
  name::String
  cost::Float64
  attributes::ListModel
end
```

When an array composed only of `Fruit` elements is passed to a listmodel, setters and getters for the roles and the constructor are all passed to QML automatically, i.e. this will automatically expose the roles `name`, `cost` and `attributes`:
```julia
# Our initial data
fruitlist = [
  Fruit("Apple", 2.45, ListModel([Attribute("Core"), Attribute("Deciduous")])),
  Fruit("Banana", 1.95, ListModel([Attribute("Tropical"), Attribute("Seedless")])),
  Fruit("Cumquat", 3.25, ListModel([Attribute("Citrus")])),
  Fruit("Durian", 9.95, ListModel([Attribute("Tropical"), Attribute("Smelly")]))]

# Set a context property with our listmodel
propmap["fruitModel"] = ListModel(fruitlist)
```
See the full example for more details, including the addition of an extra constructor to deal with the nested `ListModel` for the attributes.

## Using QTimer
`QTimer` can be used to simulate running Julia code in the background. Excerpts from [`test/gui.jl`](test/gui.jl):

```julia
const bg_counter = Observable(0)

function counter_slot()
  global bg_counter
  bg_counter[] += 1
end

@qmlfunction counter_slot

load(qml_file, timer=QTimer(), bg_counter=bg_counter)
```

Use in QML like this:
```qml
import QtQuick 2.0
import QtQuick.Controls 1.0
import QtQuick.Layouts 1.0
import org.julialang 1.0

ApplicationWindow {
    title: "My Application"
    width: 480
    height: 640
    visible: true

    Connections {
      target: timer
      onTimeout: Julia.counter_slot()
    }

    ColumnLayout {
      spacing: 6
      anchors.centerIn: parent

      Button {
          Layout.alignment: Qt.AlignCenter
          text: "Start counting"
          onClicked: timer.start()
      }

      Text {
          Layout.alignment: Qt.AlignCenter
          text: bg_counter.toString()
      }

      Button {
          Layout.alignment: Qt.AlignCenter
          text: "Stop counting"
          onClicked: timer.stop()
      }
  }
}

```

Note that QML provides the infrastructure to connect to the `QTimer` signal through the `Connections` item.

## JuliaDisplay
QML.jl provides a custom QML type named `JuliaDisplay` that acts as a standard Julia multimedia `Display`. Currently, only the `image/png` mime type is supported. Example use in QML from the `plot` example:
 ```qml
 JuliaDisplay {
   id: jdisp
   Layout.fillWidth: true
   Layout.fillHeight: true
   onHeightChanged: root.do_plot()
   onWidthChanged: root.do_plot()
 }
 ```
 The function `do_plot` is defined in the parent QML component and calls the Julia plotting routine, passing the display as an argument:
 ```qml
 function do_plot()
 {
   if(jdisp === null)
     return;

   Julia.plotsin(jdisp, jdisp.width, jdisp.height, amplitude.value, frequency.value);
 }
 ```
 Of course the display can also be added using `pushdisplay!`, but passing by value can be more convenient when defining multiple displays in QML.

## Combination with the REPL
When launching the application using `exec`, execution in the REPL will block until the GUI is closed. If you want to continue using the REPL with an active QML gui, `exec_async` provides an alternative. This method keeps the REPL active and polls the QML interface periodically for events, using a timer in the Julia event loop. An example (requiring packages Plots.jl and PyPlot.jl) can be found in `example/repl-background.jl`, to be used as:
```julia
include("example/repl-background.jl")
plot([1,2],[3,4])
```
This should display the result of the plotting command in the QML window.

## Breaking changes
* Signals in `JuliaSignals` must have arguments of type `var`
* Role indices are 1-based now on the Julia side
* The interface of some functions has changed because of the way CxxWrap handles references and pointers more strictly now
* No more automatic conversion from `String` to `QUrl`, use the `QUrl("mystring")` constructor