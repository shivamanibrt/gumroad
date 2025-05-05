# frozen_string_literal: true

class CommunitiesPresenter
  def initialize(current_user:)
    @current_user = current_user
  end

  def props
    communities = Community.where(id: current_user.accessible_communities_ids).includes(:resource, :seller)
    community_ids = communities.map(&:id)
    notification_settings = current_user.community_notification_settings
                                        .where(seller_id: communities.map(&:seller_id).uniq)
                                        .index_by(&:seller_id)

    last_read_message_timestamps = LastReadCommunityChatMessage.includes(:community_chat_message)
                                                               .where(user_id: current_user.id, community_id: community_ids)
                                                               .order(created_at: :desc)
                                                               .to_h { [_1.community_id, _1.community_chat_message.created_at] }
    unread_counts = {}

    if community_ids.any?
      values_rows = community_ids.map do |community_id|
        last_read_message_created_at = last_read_message_timestamps[community_id]
        last_read_message_created_at = "\'#{last_read_message_created_at&.iso8601(6) || Date.new(1970, 1, 1)}\'"
        "ROW(#{community_id}, #{last_read_message_created_at})"
      end.join(", ")

      join_clause = "JOIN (VALUES #{values_rows}) AS t1(community_id, last_read_community_chat_message_created_at) ON community_chat_messages.community_id = t1.community_id"

      unread_counts = CommunityChatMessage.alive
        .select("community_chat_messages.community_id, COUNT(*) as unread_count")
        .joins(join_clause)
        .where("community_chat_messages.created_at > t1.last_read_community_chat_message_created_at")
        .group(:community_id)
        .to_a
        .each_with_object({}) do |message, hash|
          hash[message.community_id] = message.unread_count
        end
    end

    communities_props = communities.map do |community|
      CommunityPresenter.new(
        community:,
        current_user:,
        extras: {
          unread_count: unread_counts[community.id] || 0,
          last_read_community_chat_message_created_at: last_read_message_timestamps[community.id]&.iso8601,
        }
      ).props
    end

    seller_id_to_external_id_map = User.where(id: notification_settings.keys).each_with_object({}) do |user, hash|
      hash[user.id] = user.external_id
    end

    {
      has_products: current_user.products.visible_and_not_archived.exists?,
      communities: communities_props,
      notification_settings: notification_settings.each_with_object({}) do |(seller_id, settings), hash|
        seller_external_id = seller_id_to_external_id_map[seller_id]
        next if seller_external_id.blank?

        hash[seller_external_id] = CommunityNotificationSettingPresenter.new(settings: settings.presence || CommunityNotificationSetting.new).props
      end,
    }
  end

  private
    attr_reader :current_user
end
