// 此檔案示範 csharp-comment skill 要求的各類型 C# 文件與說明註解格式。
// 範例以正體中文撰寫，除非 repository 已建立英文習慣。

using System;
using System.Collections.Generic;

namespace ExampleNamespace
{
    /// <summary>
    /// 管理使用者訂閱狀態，並提供訂閱到期日的計算與更新操作。
    /// 作為領域服務使用，不直接依賴資料庫；由呼叫端負責持久化。
    /// </summary>
    public class SubscriptionService
    {
        /// <summary>每個方案允許的最大裝置數量上限，超過時拒絕新增。</summary>
        private readonly int _maxDeviceCount;

        /// <summary>用於計算到期日的時鐘抽象，允許測試時替換為固定時間。</summary>
        private readonly ISystemClock _clock;

        /// <summary>
        /// 初始化 <see cref="SubscriptionService"/>。
        /// </summary>
        /// <param name="maxDeviceCount">此方案允許的最大裝置數量，必須大於零。</param>
        /// <param name="clock">系統時鐘介面，用於取得目前時間。</param>
        /// <exception cref="ArgumentOutOfRangeException">當 <paramref name="maxDeviceCount"/> 小於等於零時擲出。</exception>
        public SubscriptionService(int maxDeviceCount, ISystemClock clock)
        {
            if (maxDeviceCount <= 0)
                throw new ArgumentOutOfRangeException(nameof(maxDeviceCount), "裝置上限必須大於零。");

            _maxDeviceCount = maxDeviceCount;
            _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        }

        /// <summary>
        /// 根據方案月數計算從今日起算的到期日。
        /// </summary>
        /// <param name="planMonths">訂閱月數，必須為正整數。</param>
        /// <returns>到期日的 <see cref="DateTime"/>，時間部分固定為當天 23:59:59 UTC。</returns>
        /// <exception cref="ArgumentOutOfRangeException">當 <paramref name="planMonths"/> 小於等於零時擲出。</exception>
        public DateTime CalculateExpiryDate(int planMonths)
        {
            if (planMonths <= 0)
                throw new ArgumentOutOfRangeException(nameof(planMonths));

            // 使用 AddMonths 而非加天數，以正確處理不同月份天數差異（例如 2 月）
            var baseDate = _clock.UtcNow.Date.AddMonths(planMonths);

            // 到期日設為當天最後一刻，確保使用者可使用至該日結束
            return new DateTime(baseDate.Year, baseDate.Month, baseDate.Day, 23, 59, 59, DateTimeKind.Utc);
        }

        /// <summary>
        /// 嘗試將裝置加入訂閱，若已達裝置上限則拒絕並回傳 false。
        /// </summary>
        /// <param name="subscription">要操作的訂閱實體。</param>
        /// <param name="deviceId">要新增的裝置識別碼，不得為空白。</param>
        /// <returns>成功新增裝置時回傳 <c>true</c>；已達上限時回傳 <c>false</c>。</returns>
        /// <exception cref="ArgumentNullException">當 <paramref name="subscription"/> 為 null 時擲出。</exception>
        /// <exception cref="ArgumentException">當 <paramref name="deviceId"/> 為空白時擲出。</exception>
        public bool TryAddDevice(Subscription subscription, string deviceId)
        {
            if (subscription == null) throw new ArgumentNullException(nameof(subscription));
            if (string.IsNullOrWhiteSpace(deviceId)) throw new ArgumentException("裝置 ID 不得空白。", nameof(deviceId));

            if (subscription.DeviceIds.Count >= _maxDeviceCount)
                return false;

            subscription.DeviceIds.Add(deviceId);
            return true;
        }
    }

    /// <summary>
    /// 代表單一使用者的訂閱資料，包含方案內容與已綁定的裝置清單。
    /// </summary>
    public class Subscription
    {
        /// <summary>訂閱的唯一識別碼，由資料庫生成，不可手動指定。</summary>
        public int Id { get; set; }

        /// <summary>此訂閱歸屬的使用者識別碼。</summary>
        public string UserId { get; set; }

        /// <summary>訂閱到期的 UTC 時間；到期後系統應拒絕所有服務呼叫。</summary>
        public DateTime ExpiresAt { get; set; }

        /// <summary>
        /// 此訂閱目前已綁定的裝置識別碼清單。
        /// 清單大小受 <see cref="SubscriptionService"/> 的 maxDeviceCount 限制。
        /// </summary>
        public List<string> DeviceIds { get; set; } = new List<string>();
    }

    /// <summary>提供系統目前時間的抽象，允許在測試中替換為固定時間源。</summary>
    public interface ISystemClock
    {
        /// <summary>取得目前的 UTC 時間。</summary>
        DateTime UtcNow { get; }
    }
}
