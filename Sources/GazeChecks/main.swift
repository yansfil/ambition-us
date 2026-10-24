import Foundation

// 각 작업 패키지는 자기 *Checks.swift 파일의 함수만 수정한다.
await contractsChecks()
await gazeChecks()
await speechChecks()
await axChecks()
await overlayChecks()
await fusionChecks()
await intelligenceChecks()
await controlChecks()

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
