;;; run-tests.el --- Batch test entry point -*- lexical-binding: t; -*-
(setq load-prefer-newer t)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))
(load (expand-file-name "janitor-tests.el" (file-name-directory load-file-name)) nil t)
(ert-run-tests-batch-and-exit)
