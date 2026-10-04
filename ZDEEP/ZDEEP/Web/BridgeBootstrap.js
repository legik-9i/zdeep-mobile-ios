(() => {
    const documentId = '__ZDEEP_DOCUMENT_ID__';
    const send = (method, params = null) => window.webkit.messageHandlers.zdeepNative.postMessage({
        documentId, method, params
    }).then(reply => {
        if (reply?.ok === true) return reply.value;
        if (reply?.cancelled === true) {
            const error = new Error('The document was replaced');
            error.name = 'AbortError';
            throw error;
        }
        if (reply?.ok === false && reply.error && typeof reply.error === 'object') {
            throw reply.error;
        }
        throw new Error('Native bridge unavailable');
    });
    window.ZdeepNative = Object.freeze({
        getSession: () => send('getSession'),
        recoverUnauthorized: () => send('recoverUnauthorized'),
        getHostState: () => send('getHostState'),
        reportReady: ready => send('reportReady', ready).then(() => undefined)
    });
    window.__zdeepReceiveNativeEvent = (capturedDocumentId, name, detail) => {
        if (capturedDocumentId !== documentId) return;
        window.dispatchEvent(new CustomEvent(name, { detail }));
    };
})();
