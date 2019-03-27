class User < ApplicationRecord
  has_many :posts
  delegate :open_posts, to: :posts
end
