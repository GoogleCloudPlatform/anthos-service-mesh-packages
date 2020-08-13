.PHONY: all

# Update pkgs: asm, asm-patch, asm-citadel, asm-patch-citadel
all:
	# Update asm/
	cp -rf cluster istio project Kptfile ../asm/

	# Update asm-patch/
	cp -rf cluster-patches Kptfile ../asm-patch/
	cp -rf istio project ../asm-patch/resources/

	# Update asm-multiproject/
	cp -rf cluster istio-multiproject project Kptfile ../asm-multiproject

	# Update asm-multiproject-patch/
	cp -rf cluster-patches Kptfile ../asm-multiproject-patch/
	cp -rf istio-multiproject project ../asm-multiproject-patch/resources/