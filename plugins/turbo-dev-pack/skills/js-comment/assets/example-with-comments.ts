// 此檔案示範 js-comment skill 要求的各類型 JS/TS 文件與說明註解格式。
// 範例以正體中文撰寫，除非 repository 已建立英文習慣。

/**
 * 代表裝置訂閱方案的結構，記錄方案識別碼與允許的裝置上限。
 */
export interface SubscriptionPlan {
  /** 方案唯一識別碼，由後端生成後傳入，不可由前端修改。 */
  id: string;
  /** 此方案允許同時登入的最大裝置數量。 */
  maxDeviceCount: number;
}

/**
 * 管理使用者訂閱狀態，提供裝置新增與到期日計算功能。
 * 作為領域服務使用，不直接存取 API；由呼叫端負責資料持久化。
 */
export class SubscriptionService {
  /** 此服務所管理的訂閱方案，決定裝置上限等約束。 */
  private readonly plan: SubscriptionPlan;

  /**
   * 初始化 SubscriptionService。
   * @param plan 要套用的訂閱方案，用於決定裝置上限等規則。
   */
  constructor(plan: SubscriptionPlan) {
    this.plan = plan;
  }

  /**
   * 根據方案月數計算從今日起算的到期日。
   * @param planMonths 訂閱月數，必須為正整數。
   * @returns 到期日的 Date 物件，時間設為當天 23:59:59 UTC。
   * @throws {RangeError} 當 planMonths 小於等於零時擲出。
   */
  calculateExpiryDate(planMonths: number): Date {
    if (planMonths <= 0) throw new RangeError('planMonths 必須大於零。');

    const base = new Date();
    base.setUTCMonth(base.getUTCMonth() + planMonths);

    // 到期日設為當天最後一刻，確保使用者可使用至該日結束
    base.setUTCHours(23, 59, 59, 0);
    return base;
  }

  /**
   * 嘗試將裝置加入訂閱，若已達裝置上限則拒絕並回傳 false。
   * @param deviceIds 目前已綁定的裝置識別碼清單（直接修改此陣列）。
   * @param deviceId 要新增的裝置識別碼，不得為空字串。
   * @returns 成功新增時回傳 true；已達上限時回傳 false。
   * @throws {Error} 當 deviceId 為空白時擲出。
   */
  tryAddDevice(deviceIds: string[], deviceId: string): boolean {
    if (!deviceId.trim()) throw new Error('裝置 ID 不得為空白。');

    if (deviceIds.length >= this.plan.maxDeviceCount) return false;

    deviceIds.push(deviceId);
    return true;
  }
}

/**
 * 計算兩個訂閱方案中裝置上限較高者，並回傳對應方案。
 * 若兩者相等，優先回傳第一個方案。
 * @template T 方案型別，必須實作 SubscriptionPlan。
 * @param planA 第一個候選方案。
 * @param planB 第二個候選方案。
 * @returns 裝置上限較高的方案；若相等則回傳 planA。
 */
export function selectHigherCapacityPlan<T extends SubscriptionPlan>(planA: T, planB: T): T {
  // 相等時回傳 planA，維持呼叫端對結果的可預測性
  return planB.maxDeviceCount > planA.maxDeviceCount ? planB : planA;
}
