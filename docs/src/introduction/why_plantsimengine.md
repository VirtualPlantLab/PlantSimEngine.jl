# Why PlantSimEngine?

PlantSimEngine was created to address specific challenges in plant modeling that weren't adequately met by existing frameworks. This page outlines the motivations behind its development and explains what sets it apart.

## The Landscape of Plant Modeling Tools

Plant modeling has traditionally been approached through several different paradigms, each with its own strengths and limitations:

### Monolithic Systems

Systems like APSIM[^1], CropBox[^2], GroIMP[^3], AMAPSim[^4], Helios[^5], and CPlantBox[^6] are powerful but present several challenges:

- Massive codebases that are difficult to navigate
- Rigid structures that resist heavy modifications
- Limited flexibility for integrating new models and difficulty to handle model coupling (has to be done by hand), especially when considering multi-scale modeling
- Implementations that are difficult to modify for specific use cases
- Steep learning curves for new users with a lot of implementation details (*e.g.* complex data structures)
- Require specialized developer-modeler expertise rather than supporting researcher-developers
- Not designed for rapid hypothesis testing or model iteration

### Distributed Systems

Frameworks such as OpenAlea[^7] and Crops in Silico[^8] offer more flexibility but suffer from what's known as the "two-language problem":

- The interface language (Python) is accessible but computationally inefficient
- The computational backend is fast but difficult to modify
- Interfacing between components requires expertise in multiple languages
- Iteration cycles slow down significantly when performance optimization is needed

### Architecture-Focused Tools

Many existing tools like AMAPSim[^4] and L-Py[^9] prioritize plant architectural modeling:

- Integration of functional and environmental models is often an afterthought
- Implementation in languages like C++ or Java creates accessibility barriers
- Less suited for rapidly testing ecophysiological hypotheses

## PlantSimEngine's Innovations

PlantSimEngine addresses these limitations through several key innovations:

### Automatic Model Coupling

One of PlantSimEngine's most powerful features is its ability to automatically couple models:

- Leverages Julia's multiple-dispatch to compute the models dependency graph
- Models can be combined without writing explicit connection code
- Variables are automatically passed between processes based on dependencies, whatever the scale
- Supports multi-scale modeling with minimal effort, from organ to plant to landscape levels

### Flexibility with Control

PlantSimEngine gives researchers unprecedented control over their modeling process:

- Switch between different model implementations with a simple syntax, without modifying the models code
- Reduce degrees of freedom by fixing variables to constant values
- Force variables to use observations instead of model predictions
- Use simpler models for specific processes to reduce complexity
- Scale from single plants to complex ecosystems with the same framework

### Performance Without Compromise

Performance is a core feature, not an afterthought:

- Benchmarks show operations in the 100th of nanoseconds range for complex models
- The [PlantBiophysics.jl implementation is over 38,000 times faster](https://vezy.github.io/PlantBiophysics-paper/notebooks_performance_Fig5_PlantBiophysics_performance/) than equivalent implementations in R
- Julia's just-ahead-of-time compilation model enables both high-level abstraction and low-level performance
- Automatic parallelization across objects, time-steps, and independent processes
- Performance optimization is just a little bit more work on the same code, not a complete rewrite

### Streamlined Model Development

The framework handles tedious aspects automatically:

- Input and output variable management
- Time-step handling
- Object instantiation and tracking
- Dependency resolution between processes
- Unit propagation through integration with Unitful.jl
- Error propagation via MonteCarloMeasurements.jl

## From Research to Application

PlantSimEngine aims at bridging the gap between academic modeling and practical applications:

- Researchers can develop and refine models in a comfortable environment
- Models can be deployed in production environments with minimal modification, as a script or an executable
- The same framework works for hypothesis testing and real-world simulations
- Performance in the prototype directly translates to performance in the field

## Community-Oriented Development

PlantSimEngine is designed with the community in mind:

- MIT license encourages wide adoption and contribution
- Accessible to researchers with varying levels of programming experience
- Evolving based on real-world requirements from projects like XPalm and PlantBiophysics
- Standardized approach encourages model sharing and reproducibility

## Conclusion

By combining high-level abstraction with exceptional performance, PlantSimEngine lets researchers focus on their scientific questions rather than computational implementation details. It represents a new approach to plant modeling that emphasizes accessibility, flexibility, and efficiency—accelerating innovation in plant science and its applications.

## References

[^1]: Holzworth, D. P. et al. APSIM – Evolution towards a new generation of agricultural systems simulation. Environ. Model. Softw. 62, 327–350 (2014).
[^2]: Yun, K. & Kim, S.-H. Cropbox: a declarative crop modelling framework. Silico Plants 5, (2022).
[^3]: Kniemeyer, O. (2004). Rule-based modelling with the XL/GroIMP software. The logic of artificial life. Proceedings of 6th GWAL. AKA Akademische Verlagsges Berlin, 56-65.
[^4]: Barczi, J.-F. et al. AmapSim: A Structural Whole-plant Simulator Based on Botanical Knowledge and Designed to Host External Functional Models. Ann. Bot. 101, 1125–1138 (2008).
[^5]: Bailey, B. N. (2019). Helios: A scalable 3D plant and environmental biophysical modeling framework. Frontiers in Plant Science, 10, 1185.
[^6]: Giraud, M. et al. CPlantBox: a fully coupled modelling platform for the water and carbon fluxes in the soil–plant–atmosphere continuum. Silico Plants 5, diad009 (2023).
[^7]: Pradal, C., Dufour-Kowalski, S., Boudon, F., Fournier, C. & Godin, C. OpenAlea: a visual programming and component-based software platform for plant modelling. Funct. Plant Biol. 35, 751–760 (2008).
[^8]: Marshall-Colon, A. et al. Crops In Silico: Generating Virtual Crops Using an Integrative and Multi-scale Modeling Platform. Front. Plant Sci. 8, (2017).
[^9]: Boudon, F., Pradal, C., Cokelaer, T., Prusinkiewicz, P. & Godin, C. L-Py: An L-System Simulation Framework for Modeling Plant Architecture Development Based on a Dynamic Language. Front. Plant Sci. 3, (2012).