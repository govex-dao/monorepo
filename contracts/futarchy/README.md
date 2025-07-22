# Futarchy Contract Cardinality

<img width="773" alt="image" src="https://github.com/user-attachments/assets/099f2353-a3d0-40f5-a850-c2eb3c7717e4" />


# Sequence Diagram

<img width="1048" alt="image" src="https://github.com/user-attachments/assets/707f7a38-9fce-4a98-a6af-1edd4621cd39" />


# Linting

Using this linter https://www.npmjs.com/package/@mysten/prettier-plugin-move

Run this in root
```
npm run prettier -- -w sources/amm/amm.move  
```

Concatenating all .Move files for use with LLMs 
```
find . -type f -name '*.move' -exec cat {} + > all_moves.txt
```


```
git diff | pbcopy
```