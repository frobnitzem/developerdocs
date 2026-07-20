# CrystFEL
CrystFEL is already distributed as an AppTainer container:  
 

## Installation instructions

**Before you start,** is CrystFEL already available at your facility? CrystFEL is pre-installed at many facilities. Please check the [separate page about facility installations.](https://www.desy.de/~twhite/crystfel/facilities.html).

### Installation using [Apptainer (Singularity)](http://apptainer.org/)

The easiest way to get started is to download our container image and run it using a virtualization tool of your choice (e.g. Docker, Podman, Singularity/Apptainer).

<kbd>$ apptainer pull docker://gitlab.desy.de:5555/thomas.white/crystfel/crystfel:latest</kbd>  
<kbd>$ apptainer run -B /path/to/data crystfel_latest.sif</kbd>