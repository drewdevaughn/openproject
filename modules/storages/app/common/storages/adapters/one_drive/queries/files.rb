# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2024 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module Storages
  module Adapters
    module OneDrive
      module Queries
        class Files
          FIELDS = "?$select=id,name,size,webUrl,lastModifiedBy,createdBy,fileSystemInfo,file,folder,parentReference"
          Auth = ::Storages::Peripherals::StorageInteraction::Authentication
          Util = Peripherals::StorageInteraction::OneDrive::Util

          using Peripherals::ServiceResultRefinements

          def self.call(storage:, auth_strategy:, folder:)
            new(storage).call(auth_strategy:, folder:)
          end

          def initialize(storage)
            @storage = storage
          end

          def call(auth_strategy:, folder:)
            Auth[auth_strategy].call(storage: @storage) do |http|
              call = http.get(Util.join_uri_path(@storage.uri, children_uri_path_for(folder) + FIELDS))
              response = handle_response(call, :value)

              if response.result.empty?
                empty_response(http, folder)
              else
                response.map { |json_files| storage_files(json_files) }
              end
            end
          end

          private

          # rubocop:disable Metrics/AbcSize
          def handle_response(response, map_value)
            case response
            in { status: 200..299 }
              ServiceResult.success(result: response.json(symbolize_keys: true).fetch(map_value))
            in { status: 400 }
              ServiceResult.failure(result: :error,
                                    errors: Util.storage_error(response:, code: :error, source: self.class))
            in { status: 404 }
              ServiceResult.failure(result: :not_found,
                                    errors: Util.storage_error(response:, code: :not_found, source: self.class))
            in { status: 403 }
              ServiceResult.failure(result: :forbidden,
                                    errors: Util.storage_error(response:, code: :forbidden, source: self.class))
            in { status: 401 }
              ServiceResult.failure(result: :unauthorized,
                                    errors: Util.storage_error(response:, code: :unauthorized, source: self.class))
            else
              data = ResultData::ErrorData.new(source: self.class, payload: response)
              ServiceResult.failure(result: :error, errors: ::Storages::StorageError.new(code: :error, data:))
            end
          end

          # rubocop:enable Metrics/AbcSize

          def storage_files(json_files)
            files = json_files.map { |json| Util.storage_file_from_json(json) }

            parent_reference = json_files.first[:parentReference]
            ResultData::FolderContents.new(files, parent(parent_reference), forge_ancestors(parent_reference))
          end

          def empty_response(http, folder)
            response = http.get(Util.join_uri_path(@storage.uri, location_uri_path_for(folder) + FIELDS))
            handle_response(response, :id).map do |parent_location_id|
              empty_storage_files(folder.path, parent_location_id)
            end
          end

          def empty_storage_files(path, parent_id)
            ResultData::FolderContents.new(
              files: [],
              parent: ResultData::File.new(
                id: parent_id,
                name: path.split("/").last,
                location: path,
                permissions: %i[readable writeable]
              ),
              ancestors: forge_ancestors(path:)
            )
          end

          def parent(parent_reference)
            _, _, name = parent_reference[:path].gsub(/.*root:/, "").rpartition "/"

            if name.empty?
              root(parent_reference[:id])
            else
              ResultData::File.new(
                id: parent_reference[:id],
                name:,
                location: Util.extract_location(parent_reference),
                permissions: %i[readable writeable]
              )
            end
          end

          def forge_ancestors(parent_reference)
            path_elements = parent_reference[:path].gsub(/.+root:/, "").split("/")

            path_elements[0..-2].map do |component|
              next root(Digest::SHA256.hexdigest("i_am_root")) if component.blank?

              ResultData::File.new(id: Digest::SHA256.hexdigest(component), name: component, location: "/#{component}")
            end
          end

          def root(id) = ResultData::File.new(name: "Root", location: "/", id:, permissions: %i[readable writeable])

          def children_uri_path_for(folder)
            return "/v1.0/drives/#{@storage.drive_id}/root/children" if folder.root?

            "/v1.0/drives/#{@storage.drive_id}/root:#{encode_path(folder.path)}:/children"
          end

          def location_uri_path_for(folder)
            return "/v1.0/drives/#{@storage.drive_id}/root" if folder.root?

            "/v1.0/drives/#{@storage.drive_id}/root:#{encode_path(folder.path)}"
          end

          def encode_path(path)
            path.split("/").map { |fragment| URI.encode_uri_component(fragment) }.join("/")
          end
        end
      end
    end
  end
end
