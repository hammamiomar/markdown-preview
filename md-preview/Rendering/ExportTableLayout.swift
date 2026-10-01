nonisolated enum ExportTableLayout {
    static let prepareScript = #"""
    const tolerance = 0.5;
    const article = document.querySelector('article.markdown-body');
    if (!article) return;

    const number = value => parseFloat(value) || 0;
    const articleStyle = getComputedStyle(article);
    const articleWidth = article.getBoundingClientRect().width
        - number(articleStyle.paddingLeft) - number(articleStyle.paddingRight);

    function textRuns(cell) {
        const runs = [];
        let run = [];
        const flush = () => {
            if (run.length) runs.push(run);
            run = [];
        };
        function visit(node) {
            if (node.nodeType === Node.TEXT_NODE) {
                for (const match of node.textContent.matchAll(/\s+|\S+/gu)) {
                    if (/\s/u.test(match[0])) flush();
                    else run.push({ node, start: match.index, end: match.index + match[0].length });
                }
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (node.matches('br, wbr, code, pre, svg, math, .katex, table, img')) {
                flush();
                return;
            }
            const display = getComputedStyle(node).display;
            const block = display !== 'inline' && display !== 'contents';
            if (block) flush();
            Array.from(node.childNodes).forEach(visit);
            if (block) flush();
        }
        Array.from(cell.childNodes).forEach(visit);
        flush();
        return runs;
    }

    function wrapOversizedRuns(cell, available) {
        const runs = textRuns(cell);
        const style = getComputedStyle(cell);
        const width = available - number(style.paddingLeft) - number(style.paddingRight)
            - number(style.borderLeftWidth) - number(style.borderRightWidth);
        const originalStyle = cell.style.cssText;
        cell.style.whiteSpace = 'nowrap';
        const oversized = runs.filter(run => {
            const range = document.createRange();
            range.setStart(run[0].node, run[0].start);
            range.setEnd(run.at(-1).node, run.at(-1).end);
            return range.getBoundingClientRect().width > width + tolerance;
        });
        cell.style.cssText = originalStyle;

        // Wrap text-node pieces separately so links and emphasis keep their structure.
        oversized.flat().reverse().forEach(({ node, start, end }) => {
            const text = node.splitText(start);
            text.splitText(end - start);
            const span = document.createElement('span');
            span.style.overflowWrap = 'anywhere';
            text.replaceWith(span);
            span.append(text);
        });
    }

    Array.from(article.querySelectorAll('table')).reverse().forEach(table => {
        const available = Math.min(table.getBoundingClientRect().width, articleWidth);
        if (available <= 0) return;
        Array.from(table.rows).forEach(row => {
            Array.from(row.cells).forEach(cell => wrapOversizedRuns(cell, available));
        });

        table.style.display = 'table';
        table.style.width = 'auto';
        table.style.maxWidth = 'none';
        table.style.alignSelf = 'flex-start';
        table.style.overflow = 'visible';
        const rect = table.getBoundingClientRect();
        if (rect.width <= available + tolerance) return;

        const scale = available / rect.width;
        const style = getComputedStyle(table);
        table.style.width = rect.width + 'px';
        table.style.transformOrigin = style.direction === 'rtl' ? 'top right' : 'top left';
        table.style.transform = 'scale(' + scale + ')';
        // Transforms do not reduce the space reserved for the table in normal flow.
        table.style.marginBottom = (number(style.marginBottom) + rect.height * (scale - 1)) + 'px';
    });
    """#
}
