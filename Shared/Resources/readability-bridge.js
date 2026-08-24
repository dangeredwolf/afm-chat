(function () {
  window.__afmExtractReadableContent = function () {
    try {
      if (typeof Readability !== "function") {
        return { success: false, error: "readability_unavailable" };
      }

      var reader = new Readability(document.cloneNode(true));
      var article = reader.parse();
      if (!article) {
        return { success: false, error: "readability_null" };
      }

      return {
        success: true,
        title: article.title || document.title || "",
        excerpt: article.excerpt || "",
        textContent: article.textContent || "",
        siteName: article.siteName || "",
        length: (article.textContent || "").length,
      };
    } catch (error) {
      return { success: false, error: String(error) };
    }
  };
})();
