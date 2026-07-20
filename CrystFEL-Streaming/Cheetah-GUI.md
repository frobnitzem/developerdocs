# Cheetah-GUI
The code for the Cheetah-GUI is here:  
  
[https://github.com/cheetahdevteam/cheetah-gui](https://github.com/cheetahdevteam/cheetah-gui)  
  
The GUI creates a pattern of folders and resources (for backward compatibiity with old versions of Cheetah). This we can use to our advantage. When a run is seleted to be processed, Cheetah just fills a process template and runs it. For example:

[https://github.com/cheetahdevteam/cheetah-gui/blob/749c32f4f1ff111d97ea47579a6315a8c7cd9ce9/src/cheetah/resources/templates/lcls\_slurm\_template.sh#L1](https://github.com/cheetahdevteam/cheetah-gui/blob/749c32f4f1ff111d97ea47579a6315a8c7cd9ce9/src/cheetah/resources/templates/lcls_slurm_template.sh#L1)

```sh
#!/bin/bash
echo "Using: " $(which om_monitor)
FULLCOMMAND="mpirun om_monitor {{om_source}} -c {{om_config}} {{event_list_arg}}"
echo $FULLCOMMAND
sbatch << EOF
#!/bin/bash
#SBATCH -p {{queue}}
#SBATCH --account lcls:{{experiment_id}}
#SBATCH -t 10:00:00
#SBATCH --job-name {{job_name}}
#SBATCH --output batch.out
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=72
#SBATCH --exclusive
$FULLCOMMAND
EOF
echo "Job {{job_name}} sent to queue {{queue}}"
echo ""

```

We just need to replace this with a template that starts our infrastructure