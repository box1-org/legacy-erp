# legacy-erp

The ERP solution that the company depends on

This is a RHEL 10 image mode virtual machine, created from the Box1 golden path. It runs the legacy ERP appliance from `box1-org/box1-ops-erp-simulator` and boots directly into the ERP console. One release pipeline serves both repositories: a push to `main` in either one builds the OS image, promotes it and applies it in the VM. The repository [README](https://github.com/box1-org/legacy-erp#readme) covers the pipeline, the appliance layout, access and recovery.
