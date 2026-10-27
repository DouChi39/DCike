/// The shared reader stores the displayed page plus one (first page is 2).
/// Keep that format so SwiftUI and the existing reader resume the same page.
int nativePageFromHistory(int storedPage, int pageCount) {
  if (pageCount <= 0) return 0;
  return (storedPage - 2).clamp(0, pageCount - 1);
}

int nativePageToHistory(int page) => (page < 0 ? 0 : page) + 2;
