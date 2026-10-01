Custom CTFd themes go here, one folder per theme. `setup.sh --theme` installs
them into `<working-folder>/deploy/ctfd/themes/`, and `Dockerfile.ctfd` copies
that folder into the CTFd image, next to CTFd's own `core` and `admin` themes.
This file keeps the folder in the repository, so the image builds without themes.
