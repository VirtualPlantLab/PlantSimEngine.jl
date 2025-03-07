# Why PlantSimEngine?

PlantSimEngine was developed to address fundamental limitations in existing plant modeling tools. This framework emerged from the need for a system that could efficiently handle the complex dynamics of the soil-plant-atmosphere continuum while remaining accessible to researchers and practitioners from diverse disciplines.

## The Current Landscape of Plant Modeling

Plant modeling has evolved significantly over the years, but many existing tools face persistent challenges that limit their accessibility and efficiency. These tools generally fall into three categories:

### Monolithic Systems

Systems like APSIM[^1], GroIMP[^2], AMAPStudio[^3], Helios[^4], and CPlantBox[^5] often present significant barriers to entry and adaptation. These include:

Large, complex codebases that are difficult to navigate and modify, especially for scientists without extensive programming expertise. Researchers often spend more time understanding the implementation than developing the science behind their models.

The rigid structure of these systems can limit the integration of new scientific ideas or methodologies, as they typically follow predefined frameworks that may not accommodate novel approaches.

Many of these systems struggle with seamless multi-scale simulations and model coupling, making it challenging to represent the complex interactions between different processes in the soil-plant-atmosphere continuum.

### Distributed Systems

Platforms like OpenAlea[^6] and Crops in Silico[^7] have attempted to address some limitations of monolithic systems, but introduce their own challenges:

These systems typically use accessible interfaces (often in Python) that prioritize ease of use but suffer from computational inefficiency, making large-scale simulations time-consuming.

While their computational backends may be optimized for performance, extending or modifying them typically requires proficiency in multiple programming languages, creating a barrier for many researchers.

The iteration cycle between design, implementation, and performance tuning is often slow, hindering rapid hypothesis testing and prototyping that is essential in research contexts.

### Architecture-Focused Tools

Tools like AMAPSim[^8] excel in specific aspects but have limitations in broader applications:

These systems often prioritize structural modeling of plants over functional and environmental processes, limiting their utility for integrated studies of plant physiology and environmental responses.

Implementation in languages like C++ or Java optimizes performance but can deter potential users who lack expertise in these languages, especially researchers with backgrounds in plant science rather than computer science.

The design of these tools often makes them less suitable for rapid hypothesis testing and model prototyping, key activities in exploratory research.

## The PlantSimEngine Solution

PlantSimEngine brings together innovative ideas to overcome these limitations, offering a unique combination of features:

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

## Key Innovations

PlantSimEngine's approach to plant modeling represents a paradigm shift in how scientists can build and use models:

- **Uniform API:** Standardized interfaces make it easy to define new processes and component models, reducing the cognitive load on researchers.

- **Automatic Dependency Resolution:** The system automatically determines the relationships between different models and processes, eliminating the need for manual coupling.

- **Seamless Parallelization:** Out-of-the-box support for parallel and distributed computation allows researchers to focus on the science rather than implementation details.

- **Flexible Model Integration:** The ability to easily combine models from different sources and at different scales facilitates more comprehensive and realistic simulations.

- **User-Centric Design:** Emphasizing usability ensures that researchers with varied programming backgrounds can effectively engage with the system.

By addressing the key limitations of existing plant modeling tools, PlantSimEngine enables researchers to focus more on scientific questions and less on technical implementation details, accelerating the pace of discovery in plant science, agronomy, and related fields.

[^1]: Holzworth, D. P. et al. APSIM – Evolution towards a new generation of agricultural systems simulation. Environmental Modelling & Software 62, 327-350 (2014).

[^2]: Hemmerling, R., Kniemeyer, O., Lanwert, D., Kurth, W. & Buck-Sorlin, G. The rule-based language XL and the modelling environment GroIMP illustrated with simulated tree competition. Funct. Plant Biol. 35, 739 (2008).

[^3]: Griffon, S., and de Coligny, F. « AMAPstudio: An editing and simulation software suite for plants architecture modelling ». Ecological Modelling 290 (2014): 3‑10. https://doi.org/10.1016/j.ecolmodel.2013.10.037.

[^4]: Bailey, R. Spatial Modeling Environment for Enhancing Conifer Crown Management. Front. For. Glob. Change 3, 106 (2020).

[^5]: Schnepf, A., Leitner, D., Landl, M., Lobet, G., Mai, T. H., Morandage, S., Sheng, C., Zörner, M., Vanderborght, J., & Vereecken, H. CPlantBox: A whole-plant modelling framework for the simulation of water- and carbon-related processes. in silico Plants, 63 (2018).

[^6]: Pradal, C. et al. OpenAlea: A visual programming and component-based software platform for plant modeling. Funct. Plant Biol. 35, 751-760 (2008).

[^7]: Marshall-Colon, A. et al. Crops In Silico: Generating Virtual Crops Using an Integrative and Multi-Scale Modeling Platform. Frontiers in Plant Science 8 (2017). https://doi.org/10.3389/fpls.2017.00786.

[^8]: Barczi, J.-F., Rey, H., Caraglio, Y., Reffye, P. de, Barthélémy, D., Dong, Q. X., & Fourcaud, T. AmapSim: A Structural Whole-plant Simulator Based on Botanical Knowledge and Designed to Host External Functional Models. Annals of botany, 101(8), 1125-1138 (2008).
