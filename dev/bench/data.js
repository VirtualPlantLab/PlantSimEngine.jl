window.BENCHMARK_DATA = {
  "lastUpdate": 1758274295533,
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
      },
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
        "date": 1755555317903,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_windows/XPalm_setup",
            "value": 14601800,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9623271\nallocs=170211\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_ST",
            "value": 227683150,
            "unit": "ns",
            "extra": "gctime=33941650\nmemory=232535096\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_run",
            "value": 131286917300,
            "unit": "ns",
            "extra": "gctime=28867280250\nmemory=83886606643\nallocs=1588619569\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PSE",
            "value": 4095546400,
            "unit": "ns",
            "extra": "gctime=686509450\nmemory=2471994339\nallocs=49597643\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP",
            "value": 19327300,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623671\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_MT",
            "value": 252109100,
            "unit": "ns",
            "extra": "gctime=115557050\nmemory=757914708\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_convert_outputs",
            "value": 801649650,
            "unit": "ns",
            "extra": "gctime=63559850\nmemory=468547198\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
        "date": 1755555925964,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_mac/XPalm_setup",
            "value": 17869333,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9640648\nallocs=170001\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_ST",
            "value": 237980334,
            "unit": "ns",
            "extra": "gctime=52845208\nmemory=236116160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_run",
            "value": 284268631500,
            "unit": "ns",
            "extra": "gctime=118990014455\nmemory=83977551536\nallocs=1588364297\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PSE",
            "value": 5322516917,
            "unit": "ns",
            "extra": "gctime=641659167\nmemory=2481258160\nallocs=49720183\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP",
            "value": 11061292,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623728\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_MT",
            "value": 352110833,
            "unit": "ns",
            "extra": "gctime=175228542\nmemory=817960960\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_convert_outputs",
            "value": 956462104.5,
            "unit": "ns",
            "extra": "gctime=161712666\nmemory=468966816\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "c899efe95ad94ef34ca4588070de9c5da09b6996",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/c899efe95ad94ef34ca4588070de9c5da09b6996"
        },
        "date": 1758272909160,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_linux/XPalm_setup",
            "value": 12939562,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9614072\nallocs=169992\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_ST",
            "value": 191699494,
            "unit": "ns",
            "extra": "gctime=31360229\nmemory=232300160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_run",
            "value": 123664773481,
            "unit": "ns",
            "extra": "gctime=32507742805\nmemory=83860600096\nallocs=1588121264\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PSE",
            "value": 3810208577.5,
            "unit": "ns",
            "extra": "gctime=802046028.5\nmemory=2470024656\nallocs=49558308\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP",
            "value": 15414589,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623672\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_MT",
            "value": 264070768.5,
            "unit": "ns",
            "extra": "gctime=124454441\nmemory=753966560\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_convert_outputs",
            "value": 774273150,
            "unit": "ns",
            "extra": "gctime=110814958\nmemory=468547120\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "c899efe95ad94ef34ca4588070de9c5da09b6996",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/c899efe95ad94ef34ca4588070de9c5da09b6996"
        },
        "date": 1758273093401,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_windows/XPalm_setup",
            "value": 14901700,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9623271\nallocs=170211\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_ST",
            "value": 231054150,
            "unit": "ns",
            "extra": "gctime=35154850\nmemory=232534920\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_run",
            "value": 133256431850,
            "unit": "ns",
            "extra": "gctime=28683485200\nmemory=83838938351\nallocs=1587702230\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PSE",
            "value": 4321541350,
            "unit": "ns",
            "extra": "gctime=700810700\nmemory=2472569112\nallocs=49609338\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP",
            "value": 19250950,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623671\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_MT",
            "value": 246709400,
            "unit": "ns",
            "extra": "gctime=109234250\nmemory=757914996\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_convert_outputs",
            "value": 797640500,
            "unit": "ns",
            "extra": "gctime=84199700\nmemory=468547278\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "9ca30aa729444a0aca560f99be0092bab1c4ca35",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/9ca30aa729444a0aca560f99be0092bab1c4ca35"
        },
        "date": 1758273492310,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_linux/XPalm_setup",
            "value": 12813102,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9614072\nallocs=169992\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_ST",
            "value": 200257906.5,
            "unit": "ns",
            "extra": "gctime=32247532.5\nmemory=232300160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_run",
            "value": 140084293207,
            "unit": "ns",
            "extra": "gctime=34231433074.5\nmemory=83877303360\nallocs=1588442836\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PSE",
            "value": 3816883213,
            "unit": "ns",
            "extra": "gctime=776874599.5\nmemory=2467486576\nallocs=49507427\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP",
            "value": 15210325.5,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623672\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/PBP_multiple_timesteps_MT",
            "value": 271607099,
            "unit": "ns",
            "extra": "gctime=137400518\nmemory=753966560\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_linux/XPalm_convert_outputs",
            "value": 796578492,
            "unit": "ns",
            "extra": "gctime=92614039\nmemory=468547120\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "9ca30aa729444a0aca560f99be0092bab1c4ca35",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/9ca30aa729444a0aca560f99be0092bab1c4ca35"
        },
        "date": 1758273585830,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_windows/XPalm_setup",
            "value": 14300600,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9623191\nallocs=170211\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_ST",
            "value": 210559000,
            "unit": "ns",
            "extra": "gctime=26430500\nmemory=232535064\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_run",
            "value": 143174443800,
            "unit": "ns",
            "extra": "gctime=28875331000\nmemory=83869291080\nallocs=1588292937\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PSE",
            "value": 4566303850,
            "unit": "ns",
            "extra": "gctime=733528800\nmemory=2470111470\nallocs=49560105\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP",
            "value": 19247600,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623671\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/PBP_multiple_timesteps_MT",
            "value": 316028850,
            "unit": "ns",
            "extra": "gctime=153498400\nmemory=757913380\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_windows/XPalm_convert_outputs",
            "value": 800936800,
            "unit": "ns",
            "extra": "gctime=61946000\nmemory=468547214\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "c899efe95ad94ef34ca4588070de9c5da09b6996",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/c899efe95ad94ef34ca4588070de9c5da09b6996"
        },
        "date": 1758273781642,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_mac/XPalm_setup",
            "value": 16889208,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9640648\nallocs=170001\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_ST",
            "value": 278373937.5,
            "unit": "ns",
            "extra": "gctime=56651625\nmemory=236116160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_run",
            "value": 237692535583,
            "unit": "ns",
            "extra": "gctime=97448174379\nmemory=83994500144\nallocs=1588693749\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PSE",
            "value": 5461630250,
            "unit": "ns",
            "extra": "gctime=810411666\nmemory=2481814136\nallocs=49731484\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP",
            "value": 12352375,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623728\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_MT",
            "value": 387775354.5,
            "unit": "ns",
            "extra": "gctime=174285978.5\nmemory=817960960\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_convert_outputs",
            "value": 893030167,
            "unit": "ns",
            "extra": "gctime=156531290\nmemory=468966816\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      },
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
          "id": "9ca30aa729444a0aca560f99be0092bab1c4ca35",
          "message": "Downstream testing CI changes",
          "timestamp": "2025-09-12T04:48:11Z",
          "url": "https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154/commits/9ca30aa729444a0aca560f99be0092bab1c4ca35"
        },
        "date": 1758274292480,
        "tool": "julia",
        "benches": [
          {
            "name": "bench_mac/XPalm_setup",
            "value": 17079187,
            "unit": "ns",
            "extra": "gctime=0\nmemory=9640648\nallocs=170001\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_ST",
            "value": 232942916,
            "unit": "ns",
            "extra": "gctime=45966916\nmemory=236116160\nallocs=3330700\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_run",
            "value": 270561518792,
            "unit": "ns",
            "extra": "gctime=116339256626\nmemory=83948155288\nallocs=1587794035\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PSE",
            "value": 5002946958,
            "unit": "ns",
            "extra": "gctime=666792126\nmemory=2484155200\nallocs=49778548\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP",
            "value": 11784583,
            "unit": "ns",
            "extra": "gctime=0\nmemory=5623728\nallocs=89197\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/PBP_multiple_timesteps_MT",
            "value": 320837500,
            "unit": "ns",
            "extra": "gctime=163148166\nmemory=817960960\nallocs=3651200\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":5,\"overhead\":0,\"memory_tolerance\":0.01}"
          },
          {
            "name": "bench_mac/XPalm_convert_outputs",
            "value": 888805875,
            "unit": "ns",
            "extra": "gctime=166364375\nmemory=468966816\nallocs=6624936\nparams={\"gctrial\":true,\"time_tolerance\":0.05,\"evals_set\":false,\"samples\":10000,\"evals\":1,\"gcsample\":false,\"seconds\":120,\"overhead\":0,\"memory_tolerance\":0.01}"
          }
        ]
      }
    ]
  }
}