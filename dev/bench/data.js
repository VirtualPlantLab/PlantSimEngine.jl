window.BENCHMARK_DATA = {
  "lastUpdate": 1755555064495,
  "repoUrl": "https://github.com/VirtualPlantLab/PlantSimEngine.jl",
  "entries": {
    "Julia benchmark result": [
      {
        "commit": {
          "author": {
            "name": "VirtualPlantLab",
            "username": "VirtualPlantLab"
          },
          "committer": {
            "name": "VirtualPlantLab",
            "username": "VirtualPlantLab"
          },
          "id": "bc7633b4e5718b69c714d85247c71b54af5e216b",
          "message": "Bump actions/checkout from 4 to 5",
          "timestamp": "2025-08-11T12:29:03Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/153/commits/bc7633b4e5718b69c714d85247c71b54af5e216b"
        },
        "date": 1755555062677,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_linux/XPalm_setup",
            "value": 13322957,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9614088\nallocs=169993\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_ST",
            "value": 196686170.5,
            "unit": "ns",
            "extra": "gctime=29578278\nmemory=232300160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_run",
            "value": 123308633561.5,
            "unit": "ns",
            "extra": "gctime=31608110680\nmemory=83878649056\nallocs=1588471298\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PSE",
            "value": 3937455858.5,
            "unit": "ns",
            "extra": "gctime=760949320.5\nmemory=2472557488\nallocs=49609189\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP",
            "value": 15496793,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623672\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_MT",
            "value": 267134847,
            "unit": "ns",
            "extra": "gctime=124210154\nmemory=753966560\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_convert_outputs",
            "value": 787283335.5,
            "unit": "ns",
            "extra": "gctime=118211382.5\nmemory=468547120\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      }
    ]
  }
}