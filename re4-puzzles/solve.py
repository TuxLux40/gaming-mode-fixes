#!/usr/bin/env python3
"""Shortest solution for a 3x3 sliding-tile puzzle (breadth-first search).

usage: solve.py START [GOAL]

Boards are 9-character strings read row by row, '_' = empty cell.
GOAL defaults to "01234567_". Prints the move count, then the cells to
select in order as "row,col" pairs, ready to pass to play.sh.
"""
import sys
from collections import deque


def neighbours(board):
    gap = board.index("_")
    r, c = divmod(gap, 3)
    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        rr, cc = r + dr, c + dc
        if 0 <= rr < 3 and 0 <= cc < 3:
            tile = rr * 3 + cc
            cells = list(board)
            cells[gap], cells[tile] = cells[tile], cells[gap]
            yield "".join(cells), tile


def solve(start, goal):
    prev = {start: None}
    queue = deque([start])
    while queue:
        board = queue.popleft()
        if board == goal:
            break
        for nxt, tile in neighbours(board):
            if nxt not in prev:
                prev[nxt] = (board, tile)
                queue.append(nxt)
    if goal not in prev:
        return None
    path, board = [], goal
    while prev[board]:
        board, tile = prev[board]
        path.append(tile)
    return path[::-1]


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    start = sys.argv[1]
    goal = sys.argv[2] if len(sys.argv) == 3 else "01234567_"
    if sorted(start) != sorted(goal) or len(start) != 9 or start.count("_") != 1:
        sys.exit("START and GOAL must be 9 characters with the same tiles and one '_'")
    path = solve(start, goal)
    if path is None:
        sys.exit("unsolvable: wrong parity, so a tile is probably misidentified")
    print(len(path))
    print(" ".join("%d,%d" % divmod(t, 3) for t in path))


if __name__ == "__main__":
    main()
