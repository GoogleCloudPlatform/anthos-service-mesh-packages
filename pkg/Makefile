.PHONY: all

# Update pkgs: asm, asm-patch, asm-citadel, asm-patch-citadel
all:
	# Update asm/
	cp -rf cluster istio project Kptfile ../asm/

	# Update asm-patch/
	cp -rf cluster-patches Kptfile ../asm-patch/
	cp -rf istio project ../asm-patch/resources/

	# Update asm-citadel/
	cp -rf cluster istio-citadel project Kptfile ../asm-citadel/

	# Update asm-patch-citadel/
	cp -rf cluster-patches Kptfile ../asm-patch-citadel/
	cp -rf istio-citadel project ../asm-patch-citadel/resources/