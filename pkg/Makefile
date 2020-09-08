.PHONY: all

# Update pkgs: asm, asm-patch, asm-citadel, asm-patch-citadel
all:
	# Update asm/
	cp -rf cluster istio project options Kptfile ../asm/

	# Update asm-patch/
	cp -rf cluster-patches Kptfile ../asm-patch/
	cp -rf istio project options ../asm-patch/resources/