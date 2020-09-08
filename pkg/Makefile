.PHONY: all

# Update pkgs: asm, asm-patch
all:
	# Update asm/
	cp -rf cluster istio project options Kptfile ../asm/

	# Update asm-patch/
	cp -rf cluster-patches Kptfile ../asm-patch/
	cp -rf project ../asm-patch/resources/