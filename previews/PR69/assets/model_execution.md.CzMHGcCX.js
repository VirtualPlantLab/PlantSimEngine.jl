import{_ as e,c as a,o as t,a6 as i}from"./chunks/framework.Cj43WC4E.js";const f=JSON.parse('{"title":"Model execution","description":"","frontmatter":{},"headers":[],"relativePath":"model_execution.md","filePath":"model_execution.md","lastUpdated":null}'),l={name:"model_execution.md"},n=i(`<h1 id="Model-execution" tabindex="-1">Model execution <a class="header-anchor" href="#Model-execution" aria-label="Permalink to &quot;Model execution {#Model-execution}&quot;">​</a></h1><h2 id="Simulation-order" tabindex="-1">Simulation order <a class="header-anchor" href="#Simulation-order" aria-label="Permalink to &quot;Simulation order {#Simulation-order}&quot;">​</a></h2><p><code>PlantSimEngine.jl</code> uses the <a href="/PlantSimEngine.jl/previews/PR69/model_switching#ModelList"><code>ModelList</code></a> to automatically compute a dependency graph between the models and run the simulation in the correct order. When running a simulation with <a href="/PlantSimEngine.jl/previews/PR69/API#PlantSimEngine.run!"><code>run!</code></a>, the models are then executed following this simple set of rules:</p><ol><li><p>Independent models are run first. A model is independent if it can be run independently from other models, only using initializations (or nothing).</p></li><li><p>Then, models that have a dependency on other models are run. The first ones are the ones that depend on an independent model. Then the ones that are children of the second ones, and then their children ... until no children are found anymore. There are two types of children models (<em>i.e.</em> dependencies): hard and soft dependencies:</p></li><li><p>Hard dependencies are always run before soft dependencies. A hard dependency is a model that list dependencies in their own method for <code>dep</code>. See <a href="https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/3d91bb053ddbd087d38dcffcedd33a9db35a0fcc/examples/dummy.jl#L39" target="_blank" rel="noreferrer">this example</a> that shows <code>Process2Model</code> defining a hard dependency on any model that simulate <code>process1</code>. Inner hard dependency graphs (<em>i.e.</em> consecutive hard-dependency children) are considered as a single soft dependency.</p></li><li><p>Soft dependencies are then run sequentially. A model has a soft dependency on another model if one or more of its inputs is computed by another model. If a soft dependency has several parent nodes (<em>e.g.</em> two different models compute two inputs of the model), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.</p></li></ol><h2 id="Parallel-execution" tabindex="-1">Parallel execution <a class="header-anchor" href="#Parallel-execution" aria-label="Permalink to &quot;Parallel execution {#Parallel-execution}&quot;">​</a></h2><h3 id="FLoops" tabindex="-1">FLoops <a class="header-anchor" href="#FLoops" aria-label="Permalink to &quot;FLoops {#FLoops}&quot;">​</a></h3><p><code>PlantSimEngine.jl</code> uses the <a href="https://juliafolds.github.io/FLoops.jl/stable/" target="_blank" rel="noreferrer"><code>Floops</code></a> package to run the simulation in sequential, parallel (multi-threaded) or distributed (multi-process) computations over objects, time-steps and independent processes.</p><p>That means that you can provide any compatible executor to the <code>executor</code> argument of <a href="/PlantSimEngine.jl/previews/PR69/API#PlantSimEngine.run!"><code>run!</code></a>. By default, <a href="/PlantSimEngine.jl/previews/PR69/API#PlantSimEngine.run!"><code>run!</code></a> uses the <a href="https://juliafolds.github.io/FLoops.jl/stable/reference/api/#executor" target="_blank" rel="noreferrer"><code>ThreadedEx</code></a> executor, which is a multi-threaded executor. You can also use the <a href="https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.SequentialEx" target="_blank" rel="noreferrer"><code>SequentialEx</code></a>for sequential execution (non-parallel), or <a href="https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.DistributedEx" target="_blank" rel="noreferrer"><code>DistributedEx</code></a> for distributed computations.</p><h3 id="Parallel-traits" tabindex="-1">Parallel traits <a class="header-anchor" href="#Parallel-traits" aria-label="Permalink to &quot;Parallel traits {#Parallel-traits}&quot;">​</a></h3><p><code>PlantSimEngine.jl</code> uses <a href="https://invenia.github.io/blog/2019/11/06/julialang-features-part-2/" target="_blank" rel="noreferrer">Holy traits</a> to define if a model can be run in parallel.</p><div class="tip custom-block"><p class="custom-block-title">Note</p><p>A model is executable in parallel over time-steps if it does not uses or set values from other time-steps, and over objects if it does not uses or set values from other objects.</p></div><p>You can define a model as executable in parallel by defining the traits for time-steps and objects. For example, the <code>ToyLAIModel</code> model from the <a href="https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/main/examples" target="_blank" rel="noreferrer">examples folder</a> can be run in parallel over time-steps and objects, so it defines the following traits:</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">PlantSimEngine</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#6F42C1;--shiki-dark:#B392F0;">TimeStepDependencyTrait</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">::</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">Type{&lt;:ToyLAIModel}</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> PlantSimEngine</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">IsTimeStepIndependent</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">()</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">PlantSimEngine</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#6F42C1;--shiki-dark:#B392F0;">ObjectDependencyTrait</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">::</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">Type{&lt;:ToyLAIModel}</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> PlantSimEngine</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">IsObjectIndependent</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">()</span></span></code></pre></div><p>By default all models are considered not executable in parallel, because it is the safest option to avoid bugs that are difficult to catch, so you only need to define these traits if it is executable in parallel for them.</p><div class="tip custom-block"><p class="custom-block-title">Tip</p><p>A model that is defined executable in parallel will not necessarily will. First, the user has to pass a parallel <code>executor</code> to <a href="/PlantSimEngine.jl/previews/PR69/API#PlantSimEngine.run!"><code>run!</code></a> (<em>e.g.</em> <code>ThreadedEx</code>). Second, if the model is coupled with another model that is not executable in parallel, <code>PlantSimEngine</code> will run all models in sequential.</p></div><h3 id="Further-executors" tabindex="-1">Further executors <a class="header-anchor" href="#Further-executors" aria-label="Permalink to &quot;Further executors {#Further-executors}&quot;">​</a></h3><p>You can also take a look at <a href="https://github.com/JuliaFolds/FoldsThreads.jl" target="_blank" rel="noreferrer">FoldsThreads.jl</a> for extra thread-based executors, <a href="https://github.com/JuliaFolds/FoldsDagger.jl" target="_blank" rel="noreferrer">FoldsDagger.jl</a> for Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon <a href="https://github.com/JuliaFolds/FoldsCUDA.jl" target="_blank" rel="noreferrer">FoldsCUDA.jl</a> for GPU computations (see <a href="https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues/22" target="_blank" rel="noreferrer">this issue</a>) and <a href="https://github.com/JuliaFolds/FoldsKernelAbstractions.jl" target="_blank" rel="noreferrer">FoldsKernelAbstractions.jl</a>. You can also take a look at <a href="https://github.com/JuliaFolds/ParallelMagics.jl" target="_blank" rel="noreferrer">ParallelMagics.jl</a> to check if automatic parallelization is possible.</p><p>Finally, you can take a look into <a href="https://github.com/JuliaFolds/Transducers.jl" target="_blank" rel="noreferrer">Transducers.jl&#39;s documentation</a> for more information, for example if you don&#39;t know what is an executor, you can look into <a href="https://juliafolds.github.io/Transducers.jl/stable/explanation/glossary/#glossary-executor" target="_blank" rel="noreferrer">this explanation</a>.</p><h2 id="Tutorial" tabindex="-1">Tutorial <a class="header-anchor" href="#Tutorial" aria-label="Permalink to &quot;Tutorial {#Tutorial}&quot;">​</a></h2><p>You can learn how to run a simulation from <a href="/PlantSimEngine.jl/previews/PR69/index#PlantSimEngine">the home page</a>, or from the <a href="https://vezy.github.io/PlantBiophysics.jl/stable/simulation/first_simulation/" target="_blank" rel="noreferrer">documentation of PlantBiophysics.jl</a>.</p>`,20),s=[n];function o(r,d,h,c,p,u){return t(),a("div",null,s)}const g=e(l,[["render",o]]);export{f as __pageData,g as default};