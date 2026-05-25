# 技術仕様書：WinCacheRemover.ps1

## 概要
Windowsシステムおよび全ユーザーのキャッシュ・一時ファイルを安全に削除するスクリプト。
セキュリティ監査に基づく修正（NTFSジャンクション対策、設定バリデーション）を経て、安全性と信頼性が確保されています。

## 特徴
* **日英バイリンガル対応**: コンソール出力および設定ファイルの解説を日英併記。
* **文字化け対策**: UTF-8 エンコーディングを強制し、日本語表示を安定化。
* **安全な再帰処理**: ReparsePoint（リンク）を検知してスキップするカスタム関数を実装。
* **堅牢な設定管理**: 型検証と範囲チェックを行い、不正入力時は安全なデフォルト値を使用。

## 変数定義
| 変数名 | 型 | 説明 |
| :--- | :--- | :--- |
| `$PSScriptRoot` | string | スクリプトの実行ディレクトリ（基準パス）。 |
| `$Config` | hashtable | `config.txt` から読み込まれ、バリデーション済みの設定項目。 |
| `$LastRunPath` | string | 前回実行日時を記録する `last_run.txt` のフルパス。 |
| `$ThresholdDate` | datetime | 削除対象を判定するための基準日時（現在時刻 - `MinFileAgeDays`）。 |
| `$FinalTargets` | string[] | ワイルドカード展開およびソートが完了した削除対象ディレクトリのリスト。 |
| `$Global:TotalFreedBytes` | long | 実行中に解放された合計バイト数。 |

## 関数定義
### `Write-Log($Message)`
* **役割**: タイムスタンプ付きメッセージをログファイルに追記する。
* **依存先**: `$LogFile`, `$Config.LogDirectory`

### `Format-Size($Bytes)`
* **役割**: バイト数を適切な単位（GB, MB, KB, B）の文字列に変換する。
* **依存先**: なし

### `Validate-PositiveInt($Value, $Default)`
* **役割**: 入力文字列が正の整数か検証し、不正ならデフォルト値を返す。
* **依存先**: なし

### `Get-SafeChildItem($Path, $FileOnly)`
* **役割**: Junction等を無視して安全に再帰スキャンを行う。
* **依存先**: `Write-Log`
* **影響範囲**: 全てのファイル削除工程。この関数の不具合は「削除漏れ」または「不正削除」に直結する。

## 依存関係マッピング
### 内部依存関係
* **初期化フェーズ**:
    * `$Config` は `Validate-PositiveInt` を使用して正規化される。
    * `$LogFile` は `$Config.LogDirectory` に依存する。
* **実行判定フェーズ**:
    * 判定ロジックは `$LastRunPath` の内容と `$Config.ExecutionIntervalDays` に依存する。
* **削除フェーズ**:
    * `Get-SafeChildItem` は `$ThresholdDate` と連動して削除対象ファイルを特定する。
    * ファイル削除ループは `Get-SafeChildItem` の戻り値に依存する（ERR-001修正により解決）。

### 外部依存関係
* **ファイルシステム**: `C:\Users` 以下のディレクトリ構造、`C:\Windows\Temp` 等のシステムパス。
* **権限**: システムファイルおよび他ユーザーのファイル削除のため、管理者権限が必要。

## 変更時の影響スコープ（Impact Scope）
* **`Get-SafeChildItem` の変更**: 削除の安全性（リンク追跡）と網羅性（再帰の深さ）に影響。
* **`$Config` バリデーションの変更**: ユーザー設定の柔軟性と、不正設定によるスクリプト停止リスクに影響。
* **`last_run.txt` 更新タイミングの変更**: 実行の原子性に影響。現在は全工程完了後にのみ更新される。
