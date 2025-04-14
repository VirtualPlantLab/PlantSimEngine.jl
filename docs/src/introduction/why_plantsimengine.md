# Why PlantSimEngine?

PlantSimEngine was developed to address fundamental limitations in existing plant modeling tools. This framework emerged from the need for a system that could efficiently handle the complex dynamics of the soil-plant-atmosphere continuum while remaining accessible to researchers and practitioners from diverse disciplines.

## The Current Landscape of Plant Modeling

Plant modeling has evolved significantly over the years, with different tools making different design tradeoffs to address specific research needs. These tools generally fall into three categories, each with their own strengths and limitations:

### Monolithic Systems

Systems like APSIM[^1], GroIMP[^2], AMAPStudio[^3], Helios[^4], and CPlantBox[^5] offer comprehensive functionality but present certain tradeoffs:

These systems provide robust, well-tested frameworks with established scientific validity, but their large, complex codebases can be challenging to navigate and modify without extensive programming expertise.

Their comprehensive architecture offers a wealth of integrated features but may require adaptation when implementing novel approaches that don't align with their predefined frameworks.

They excel at specific types of simulations but may require additional engineering effort for seamless multi-scale simulations and model coupling across the soil-plant-atmosphere continuum.

These platforms typically require dedicated engineering resources for maintenance and extension, with research teams often needing specialized technical staff to implement new models.

### Distributed Systems

Platforms like OpenAlea[^6] and Crops in Silico[^7] offer different advantages and tradeoffs:

These systems provide accessible interfaces (often in Python) that prioritize ease of use and flexibility, making them approachable for many researchers, though they may require performance optimization for large-scale simulations.

Their modular nature facilitates component reuse and integration, while sometimes requiring proficiency in multiple programming languages for extending computational backends.

They support diverse modeling paradigms but may involve a longer iteration cycle between design, implementation, and performance tuning compared to more specialized tools.

While offering flexibility, implementing complex models often requires significant developer time, especially when optimizing performance using lower-level languages.

### Architecture-Focused Tools

Tools like AMAPSim[^8] make specific design choices that benefit certain applications:

These systems excel in their focused domains (such as structural modeling of plants) while requiring integration with other tools for comprehensive studies of plant physiology and environmental responses.

Their implementation in languages like C++ or Java delivers excellent performance but represents a tradeoff in terms of accessibility for researchers without expertise in these languages.

They provide sophisticated functionality in their target domains but may require additional work for rapid hypothesis testing and model prototyping across diverse aspects of plant science.

## The PlantSimEngine Solution

PlantSimEngine brings together innovative ideas to address these various tradeoffs, offering a unique combination of features:

### Automatic Model Coupling

**Seamless Integration:** PlantSimEngine leverages Julia's multiple-dispatch capabilities to automatically compute the dependency graph between models. This allows researchers to effortlessly couple models without writing complex connection code or manually managing dependencies.

**Intuitive Multi-Scale Support:** The framework naturally handles models operating at different scales—from organelle to ecosystem—connecting them with minimal effort and maintaining consistency across scales.

### Flexibility with Precision Control

**Effortless Model Switching:** Researchers can switch between different component models using a simple syntax without rewriting the underlying model code. This enables rapid comparison between different hypotheses and model versions, accelerating the scientific discovery process.

**Fine-Grained Model Control:** PlantSimEngine allows users to fix parameters, force variables to match observed values, or select simpler models for specific processes. This flexibility helps reduce overall system complexity while maintaining precision where it matters most.

**Adaptive Scalability:** The same framework efficiently supports both simple prototypes for single-plant studies and complex ecosystem simulations, scaling computational resources appropriately to the problem at hand.

### Outstanding Performance

**High-Speed Computation:** Benchmarks demonstrate operations completing in hundreds of nanoseconds, making PlantSimEngine suitable for computationally intensive applications. For example, the [PlantBiophysics.jl implementation is over 38,000 times faster](https://vezy.github.io/PlantBiophysics-paper/notebooks_performance_Fig5_PlantBiophysics_performance/) than equivalent implementations in R.

**Computational Efficiency:** Julia's just-ahead-of-time compilation and native support for parallelism ensure that optimizations made during prototyping directly transfer to larger-scale applications, eliminating the need for reimplementation in a different language for performance gains.

### Developer Efficiency

**Reduced Implementation Time:** PlantSimEngine leverages Julia's dynamic language features while maintaining the performance of statically-compiled languages. This significantly reduces the time researchers spend implementing and optimizing models.

**Modular Building Blocks:** The component-based architecture allows models to be built as unit components that can be stacked like building blocks to create complex systems. This modularity dramatically increases code reuse and reduces redundant implementation efforts.

**No Engineering Overhead:** Unlike monolithic systems that require dedicated engineering teams or distributed platforms that need backend optimization, PlantSimEngine enables domain scientists to independently develop high-performance models without specialized programming expertise.

**Rapid Prototyping to Production:** The same code used for quick prototyping can transition directly to production-scale simulations without rewriting, eliminating the traditional gap between exploratory research and application.

## Key Innovations

PlantSimEngine's approach to plant modeling represents a paradigm shift in how scientists can build and use models:

- **Uniform API:** Standardized interfaces make it easy to define new processes and component models, reducing the cognitive load on researchers.

- **Automatic Dependency Resolution:** The system automatically determines the relationships between different models and processes, eliminating the need for manual coupling.

- **Seamless Parallelization:** Out-of-the-box support for parallel and distributed computation allows researchers to focus on the science rather than implementation details.

- **Flexible Model Integration:** The ability to easily combine models from different sources and at different scales facilitates more comprehensive and realistic simulations.

- **User-Centric Design:** Emphasizing usability ensures that researchers with varied programming backgrounds can effectively engage with the system.

By offering solutions to the various tradeoffs present in existing modeling approaches, PlantSimEngine enables researchers to focus more on scientific questions and less on technical implementation details, accelerating the pace of discovery in plant science, agronomy, and related fields.

[^1]: Holzworth, D. P. et al. APSIM – Evolution towards a new generation of agricultural systems simulation. Environmental Modelling & Software 62, 327-350 (2014).

[^2]: Hemmerling, R., Kniemeyer, O., Lanwert, D., Kurth, W. & Buck-Sorlin, G. The rule-based language XL and the modelling environment GroIMP illustrated with simulated tree competition. Funct. Plant Biol. 35, 739 (2008).

[^3]: Griffon, S., and de Coligny, F. AMAPstudio: An editing and simulation software suite for plants architecture modelling. Ecological Modelling 290 (2014): 3‑10. <https://doi.org/10.1016/j.ecolmodel.2013.10.037>.

[^4]: Bailey, R. Spatial Modeling Environment for Enhancing Conifer Crown Management. Front. For. Glob. Change 3, 106 (2020).

[^5]: Schnepf, A., Leitner, D., Landl, M., Lobet, G., Mai, T. H., Morandage, S., Sheng, C., Zörner, M., Vanderborght, J., & Vereecken, H. CPlantBox: A whole-plant modelling framework for the simulation of water- and carbon-related processes. in silico Plants, 63 (2018).

[^6]: Pradal, C. et al. OpenAlea: A visual programming and component-based software platform for plant modeling. Funct. Plant Biol. 35, 751-760 (2008).

[^7]: Marshall-Colon, A. et al. Crops In Silico: Generating Virtual Crops Using an Integrative and Multi-Scale Modeling Platform. Frontiers in Plant Science 8 (2017). <https://doi.org/10.3389/fpls.2017.00786>.

[^8]: Barczi, J.-F., Rey, H., Caraglio, Y., Reffye, P. de, Barthélémy, D., Dong, Q. X., & Fourcaud, T. AmapSim: A Structural Whole-plant Simulator Based on Botanical Knowledge and Designed to Host External Functional Models. Annals of botany, 101(8), 1125-1138 (2008).
