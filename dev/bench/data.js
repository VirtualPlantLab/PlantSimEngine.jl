window.BENCHMARK_DATA = {
  "lastUpdate": 1737986075170,
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
            "email": "samuel.mackeown@cirad.fr",
            "name": "Samuel-AMAP",
            "username": "Samuel-amap"
          },
          "distinct": true,
          "id": "b071640d7a168947a9adea65e5cb3b24d5e5710c",
          "message": "Reenable manual workflow triggering, and for pushes on the test branch",
          "timestamp": "2025-01-27T14:46:51+01:00",
          "tree_id": "c6ed8ae73f3ccdba13919347750c868668d907f4",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/commit/b071640d7a168947a9adea65e5cb3b24d5e5710c"
        },
        "date": 1737986073787,
        "tool": "julia",
        "benches": [
          {
            "name": "bench/PSE",
            "value": 2498720210,
            "unit": "ns",
            "extra": "gctime=330638555\nmemory=1567982448\nallocs=33348794\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench/PBP",
            "value": 19808488.5,
            "unit": "ns",
            "extra": "gctime=0\nmemory=6290864\nallocs=101797\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      }
    ]
  }
}