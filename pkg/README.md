# How to update shared files

The pkg/ folder contains the shared common files used by asm/, asm-patch/ and other asm* packages in this repo.

## Instructions on how to update a common file

1. Go to pkg folder.
   ```bash
   cd pkg
   ```

2. Update files in pkg/.

3. Run `make` to update packages (e.g., asm/ and asm-patch/) in this repo.
   ```bash
   make
   ```
4. Create a PR including the changes.
