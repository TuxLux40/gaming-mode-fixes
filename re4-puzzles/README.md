# RE4 (2005) tile puzzle solver

Solves the 3×3 sliding-tile puzzle Ashley has to complete in the castle
(Salazar crest, motto "Discover truth in sacrifices and …"). Works for any
3×3 sliding puzzle; the RE4 specifics are the tile identification below.

## Steps

1. Screenshot the board and label each cell with the tile number it holds
   (table below). The empty cell is `_`.
2. `./solve.py <start>` prints the shortest move list (BFS, instant).
3. `./play.sh <cursor_row> <cursor_col> <moves…>` enters it in the game.
   Rows and columns count from 0 at the top left.
4. Screenshot to confirm. The game then says "There's still a piece
   missing…": put the ninth piece (from the fireplace) into the bottom
   right cell.

## Solved layout (goal `01234567_`)

| | col 0 | col 1 | col 2 |
|---|---|---|---|
| **row 0** | 0 star, vines bottom **right** | 1 eagle/crown | 2 star, vines bottom **left** |
| **row 1** | 3 vines on the tile's **right** side | 4 helmet + shield top (insect emblem) | 5 vines on the tile's **left** side |
| **row 2** | 6 star + "Discover truth" scroll | 7 shield bottom + "in sacrifices" | `_` (fireplace piece) |

## Telling tiles apart

- The two star tiles in the top corners and the two vine tiles are mirror
  images. Judge them by which side the vines sit on, not by the motif.
- The empty cell is a dark pit with its own engraving (a star in one game,
  a sunburst in another). Don't mistake it for a tile; it is recessed and
  darker.
- If `solve.py` reports "unsolvable", two tiles are swapped in your
  labelling (an odd number of inversions can never be reached by sliding).

## Example (2026-10-31)

```
start: 1 2 5 / 4 _ 7 / 0 3 6   cursor at bottom right
./solve.py 1254_7036          → 12 moves
./play.sh 2 2 1,0 2,0 2,1 2,2 1,2 0,2 0,1 0,0 1,0 2,0 2,1 2,2
```
