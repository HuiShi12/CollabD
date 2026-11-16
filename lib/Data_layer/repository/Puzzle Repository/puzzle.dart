import 'dart:math';

class PuzzlePieceData {
  final int pieceId;
  final int correctIndex;
  int currentIndex;

  PuzzlePieceData({
    required this.pieceId,
    required this.correctIndex,
    required this.currentIndex,
  });

  bool get isCorrect => pieceId == currentIndex;

  PuzzlePieceData copyWith({
    int? pieceId,
    int? correctIndex,
    int? currentIndex,
  }) {
    return PuzzlePieceData(
      pieceId: pieceId ?? this.pieceId,
      correctIndex: correctIndex ?? this.correctIndex,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }
}

class PuzzleRepository {
  final Random _random = Random();

  List<PuzzlePieceData> createNinePiecePuzzle() {
    final List<int> shuffledPieceIds = List.generate(9, (index) => index);

    do {
      shuffledPieceIds.shuffle(_random);
    } while (_isSolvedOrder(shuffledPieceIds));

    return List.generate(9, (currentIndex) {
      final pieceId = shuffledPieceIds[currentIndex];

      return PuzzlePieceData(
        pieceId: pieceId,
        correctIndex: pieceId,
        currentIndex: currentIndex,
      );
    });
  }

  List<PuzzlePieceData> swapPieces({
    required List<PuzzlePieceData> pieces,
    required int firstIndex,
    required int secondIndex,
  }) {
    final updatedPieces = pieces
        .map(
          (piece) => piece.copyWith(),
    )
        .toList();

    final firstPiece = updatedPieces[firstIndex];
    final secondPiece = updatedPieces[secondIndex];

    updatedPieces[firstIndex] = secondPiece.copyWith(
      currentIndex: firstIndex,
    );

    updatedPieces[secondIndex] = firstPiece.copyWith(
      currentIndex: secondIndex,
    );

    return updatedPieces;
  }

  bool isPuzzleSolved(List<PuzzlePieceData> pieces) {
    if (pieces.length != 9) return false;

    for (int index = 0; index < pieces.length; index++) {
      final piece = pieces[index];

      if (piece.pieceId != index) {
        return false;
      }

      if (piece.currentIndex != index) {
        return false;
      }
    }

    return true;
  }

  List<PuzzlePieceData> createSolvedPuzzle() {
    return List.generate(
      9,
          (index) => PuzzlePieceData(
        pieceId: index,
        correctIndex: index,
        currentIndex: index,
      ),
    );
  }

  int? getFirstWrongPieceIndex(List<PuzzlePieceData> pieces) {
    for (int index = 0; index < pieces.length; index++) {
      if (pieces[index].pieceId != index) {
        return index;
      }
    }

    return null;
  }

  /// Every board position that currently holds the wrong tile.
  Set<int> getWrongPieceIndices(List<PuzzlePieceData> pieces) {
    final wrong = <int>{};
    for (int index = 0; index < pieces.length; index++) {
      if (pieces[index].pieceId != index) wrong.add(index);
    }
    return wrong;
  }

  bool _isSolvedOrder(List<int> pieceIds) {
    for (int index = 0; index < pieceIds.length; index++) {
      if (pieceIds[index] != index) {
        return false;
      }
    }

    return true;
  }
}