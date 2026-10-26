# Web bridge

Контракт бриджа ограничен файлами `NativeBridge.swift`, `BridgeModels.swift` и
`BridgeBootstrap.js`.

При каждом коммите, меняющем любой из этих файлов, увеличивай patch-версию
`NativeBridge.version` на 1 относительно родительского коммита. В этом первом
коммите задай начальную версию `0.0.1`. Git hook не добавлять.
