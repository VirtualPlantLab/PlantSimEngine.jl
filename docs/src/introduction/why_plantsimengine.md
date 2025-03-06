
PlantSimEngine arose out of a perceived need for a new modelling framework for ecophysiological and FSPM simulations.

## Goals

## Existing FSPM systems

### Monoliths

Often massive codebases
Rigid
Implicit hypothesis
Parameters hard to change

E.g. APSIM[^1], CropBox[^2], GroIMP[^3], AMAPSim[^4], Helios[^5], CPlantBox[^6]

### Distributed Systems

E.g. OpenAlea[^7], Crops in silico[^8]

The two-language problem presents challenges in integration and usability.

### Other Tools

Architectural primary focus (e.g. AMAPSim[^4], L-Py[^9]) where adding functional and environmental models is less straightforward

C++, Java = less accessible
User interface is important for models users, and also for prototyping and debugging faster
Less tailored to autonomous 'researcher-developer', requires a 'developer-modeller'

# References

[^1]: Holzworth, D. P. et al. APSIM – Evolution towards a new generation of agricultural systems simulation. Environ. Model. Softw. 62, 327–350 (2014).
[^2]: Yun, K. & Kim, S.-H. Cropbox: a declarative crop modelling framework. Silico Plants 5, (2022).
[^3]: Kniemeyer, O. (2004). Rule-based modelling with the XL/GroIMP software. The logic of artificial life. Proceedings of 6th GWAL. AKA Akademische Verlagsges Berlin, 56-65.
[^4]: Barczi, J.-F. et al. AmapSim: A Structural Whole-plant Simulator Based on Botanical Knowledge and Designed to Host External Functional Models. Ann. Bot. 101, 1125–1138 (2008).
[^5]: Bailey, B. N. (2019). Helios: A scalable 3D plant and environmental biophysical modeling framework. Frontiers in Plant Science, 10, 1185.
[^6]: Giraud, M. et al. CPlantBox: a fully coupled modelling platform for the water and carbon fluxes in the soil–plant–atmosphere continuum. Silico Plants 5, diad009 (2023).
[^7]: Pradal, C., Dufour-Kowalski, S., Boudon, F., Fournier, C. & Godin, C. OpenAlea: a visual programming and component-based software platform for plant modelling. Funct. Plant Biol. 35, 751–760 (2008).
[^8]: Marshall-Colon, A. et al. Crops In Silico: Generating Virtual Crops Using an Integrative and Multi-scale Modeling Platform. Front. Plant Sci. 8, (2017).
[^9]: Boudon, F., Pradal, C., Cokelaer, T., Prusinkiewicz, P. & Godin, C. L-Py: An L-System Simulation Framework for Modeling Plant Architecture Development Based on a Dynamic Language. Front. Plant Sci. 3, (2012).