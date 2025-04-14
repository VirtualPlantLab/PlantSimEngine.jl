window.BENCHMARK_DATA = {
  "lastUpdate": 1744641672913,
  "repoUrl": "https://github.com/VirtualPlantLab/PlantSimEngine.jl",
  "entries": {
    "Julia benchmark result": [
      {
        "commit": {
          "author": {
            "email": "samuel.mackeown@cirad.fr",
            "name": "Samuel-AMAP",
            "username": "Samuel-amap"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "7e352d44ee88ac1f35c6dd724ee6e3a88c39ff80",
          "message": "Merge pull request #128 from VirtualPlantLab/Outputs-filtering2\n\nOutputs filtering ; see comments for detailed summary of most changes",
          "timestamp": "2025-04-14T15:46:00+02:00",
          "tree_id": "2aec0a3c87c20e9517319daaa792478522c9837b",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/commit/7e352d44ee88ac1f35c6dd724ee6e3a88c39ff80"
        },
        "date": 1744641671814,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_linux/PBP_multiple_timesteps_ST",
            "value": 482442737.5,
            "unit": "ns",
            "extra": "gctime=64118383.5\nmemory=644529600\nallocs=10022000\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PSE",
            "value": 2475054470,
            "unit": "ns",
            "extra": "gctime=216096441\nmemory=1563483264\nallocs=33258671\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP",
            "value": 24340546.5,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9567664\nallocs=159097\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_MT",
            "value": 432739491,
            "unit": "ns",
            "extra": "gctime=141841484\nmemory=1164886400\nallocs=10372900\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      }
    ]
  }
}