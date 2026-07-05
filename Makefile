# Kiln out-of-tree module Makefile.
#   make            - build against the running kernel (or KDIR=...)
#   make KDIR=/path/to/your/mainline/build
#   make clean
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
