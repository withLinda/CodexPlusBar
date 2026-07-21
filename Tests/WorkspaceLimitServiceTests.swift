import Foundation
import Testing
@testable import CodexPlusBar

struct WorkspaceLimitServiceTests {
    @Test
    func decodesWindowWithoutUnusedDurationFields() throws {
        let data = Data(
            """
            {
              "account_id": "workspace-a",
              "plan_type": "team",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "reset_at": 1773819260
                }
              }
            }
            """.utf8
        )

        let snapshot = try WorkspaceLimitService.decodeSnapshot(
            from: data,
            workspaceID: "workspace-a"
        )

        #expect(snapshot.primaryWindow.remainingPercent == 75)
        #expect(snapshot.primaryWindow.resetAt == Date(timeIntervalSince1970: 1_773_819_260))
    }

    @Test
    func decodesPrimaryAndSecondaryWindowsEvenWhenCodeReviewPayloadExists() throws {
        let data = Data(
            """
            {
              "account_id": "workspace-a",
              "plan_type": "team",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 7200,
                  "reset_at": 1773819260
                },
                "secondary_window": {
                  "used_percent": 60,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400,
                  "reset_at": 1774406060
                }
              },
              "code_review_rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 10,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400,
                  "reset_at": 1774406254
                },
                "secondary_window": null
              }
            }
            """.utf8
        )

        let snapshot = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")

        #expect(snapshot.workspaceID == "workspace-a")
        #expect(snapshot.primaryWindow.remainingPercent == 75)
        #expect(snapshot.secondaryWindow?.remainingPercent == 40)
    }

    @Test
    func decodesAccountsDictionaryPayloadForMatchedWorkspace() throws {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "name": "Alpha Team",
                    "plan_type": "team"
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 55,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 600,
                      "reset_at": 1773819260
                    },
                    "secondary_window": {
                      "used_percent": 12,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 86400,
                      "reset_at": 1774406060
                    }
                  },
                  "code_review_rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 7,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 3600,
                      "reset_at": 1774406254
                    }
                  }
                }
              },
              "account_ordering": ["workspace-a"]
            }
            """.utf8
        )

        let snapshot = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")

        #expect(snapshot.accountID == "workspace-a")
        #expect(snapshot.planType == "team")
        #expect(snapshot.primaryWindow.remainingPercent == 45)
        #expect(snapshot.secondaryWindow?.remainingPercent == 88)
    }

    @Test
    func matchesWorkspaceByDictionaryKeyFallback() throws {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-fallback": {
                  "plan_type": "team",
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 35,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 120,
                      "reset_at": 1773819260
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let snapshot = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-fallback")

        #expect(snapshot.accountID == "workspace-fallback")
        #expect(snapshot.planType == "team")
        #expect(snapshot.primaryWindow.remainingPercent == 65)
    }

    @Test
    func findsNestedLimitContainersInsideMatchedWorkspaceOnly() throws {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "plan_type": "team"
                  },
                  "usage": {
                    "limits": {
                      "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                          "used_percent": 40,
                          "limit_window_seconds": 18000,
                          "reset_after_seconds": 300,
                          "reset_at": 1773819260
                        },
                        "secondary_window": null
                      },
                      "code_review_rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                          "used_percent": 15,
                          "limit_window_seconds": 604800,
                          "reset_after_seconds": 7200,
                          "reset_at": 1774406254
                        }
                      }
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let snapshot = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")

        #expect(snapshot.primaryWindow.remainingPercent == 60)
    }

    @Test
    func requestedWorkspaceDoesNotBorrowLimitFromDifferentAccount() {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "plan_type": "team"
                  }
                },
                "workspace-b": {
                  "account": {
                    "account_id": "workspace-b",
                    "plan_type": "team"
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 9,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 60,
                      "reset_at": 1773819260
                    }
                  }
                }
              }
            }
            """.utf8
        )

        do {
            _ = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")
            Issue.record("Expected an unsupported error.")
        } catch let error as ChatGPTAPIError {
            switch error {
            case let .unsupported(message):
                #expect(message.contains("format changed"))
                #expect(message.contains("TRACE_PRIVATE_API=1"))
            default:
                Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
            }
        } catch {
            Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
        }
    }

    @Test
    func missingSelectedWorkspaceDoesNotBorrowOtherWorkspaceLimit() {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-b": {
                  "account": {
                    "account_id": "workspace-b",
                    "plan_type": "team"
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 9,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 60,
                      "reset_at": 1773819260
                    }
                  }
                }
              }
            }
            """.utf8
        )

        do {
            _ = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")
            Issue.record("Expected an unsupported error.")
        } catch let error as ChatGPTAPIError {
            switch error {
            case let .unsupported(message):
                #expect(message.contains("other workspaces"))
                #expect(message.contains("TRACE_PRIVATE_API=1"))
            default:
                Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
            }
        } catch {
            Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
        }
    }

    @Test
    func authenticatedAccountsPayloadWithoutUsableLimitThrowsUnsupportedWithTraceHint() {
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "plan_type": "team"
                  },
                  "usage": {
                    "limits": {
                      "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                          "used_percent": 25,
                          "limit_window_seconds": 18000,
                          "reset_after_seconds": 600,
                          "reset_at": 0
                        }
                      }
                    }
                  }
                }
              }
            }
            """.utf8
        )

        do {
            _ = try WorkspaceLimitService.decodeSnapshot(from: data, workspaceID: "workspace-a")
            Issue.record("Expected an unsupported error.")
        } catch let error as ChatGPTAPIError {
            switch error {
            case let .unsupported(message):
                #expect(message.contains("format changed"))
                #expect(message.contains("/backend-api/wham/usage"))
            default:
                Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
            }
        } catch {
            Issue.record("Expected ChatGPTAPIError.unsupported, got \(error).")
        }
    }
}
