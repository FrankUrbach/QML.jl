mydir, myname = splitdir(@__FILE__)

excluded = ["glvisualize.jl"]

cd(mydir) do
  for fname in readdir()
    if fname != myname && endswith(fname, ".jl") && fname ∉ excluded
      println("running example ", fname, "...")
      run(`$(Base.julia_cmd()) $fname`)
    end
  end
end
